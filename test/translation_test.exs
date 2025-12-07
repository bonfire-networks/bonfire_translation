defmodule Bonfire.Translation.Test do
  use Bonfire.DataCase, async: false

  alias Bonfire.Translation
  alias Bonfire.Common.Cache

  setup do
    # Clear any test adapter state
    Process.delete(:test_adapter_fail)
    Process.delete(:test_adapter_unavailable)

    # Clear translation cache before each test
    Cache.remove_all()

    # Configure to use test adapter
    Process.put(:bonfire_translation_adapters, [Bonfire.Translation.TestAdapter])

    :ok
  end

  describe "translate/3" do
    test "translates text to target language" do
      assert {:ok, "[auto->es] Hello"} = Translation.translate("Hello", "es")
    end

    test "returns error for empty text" do
      assert {:error, :empty_text} = Translation.translate("", "es")
    end

    test "normalizes language codes to lowercase" do
      assert {:ok, "[auto->es] Hello"} = Translation.translate("Hello", "ES")
    end
  end

  describe "translate/4" do
    test "translates with explicit source language" do
      assert {:ok, "[en->es] Hello"} = Translation.translate("Hello", "en", "es", [])
    end

    test "passes nil source language for auto-detect" do
      assert {:ok, "[auto->fr] Hello"} = Translation.translate("Hello", nil, "fr", [])
    end
  end

  describe "caching" do
    test "caches translation results" do
      # First call
      assert {:ok, "[auto->es] Hello"} = Translation.translate("Hello", "es")

      # Make adapter fail - if cache works, we should still get result
      Process.put(:test_adapter_fail, true)

      # Second call should use cache
      assert {:ok, "[auto->es] Hello"} = Translation.translate("Hello", "es")
    end

    test "caches language detection results" do
      # First call
      assert {:ok, %{language: "fr", confidence: _}} =
               Translation.detect_language("bonjour")

      # Make adapter fail
      Process.put(:test_adapter_fail, true)

      # Should use cached result
      assert {:ok, %{language: "fr", confidence: 1.0}} =
               Translation.detect_language("bonjour")
    end
  end

  describe "translate_batch/4" do
    test "translates multiple texts" do
      texts = ["Hello", "World", "Test"]

      assert {:ok, results} = Translation.translate_batch(texts, nil, "es")
      assert length(results) == 3
      assert "[auto->es] Hello" in results
      assert "[auto->es] World" in results
      assert "[auto->es] Test" in results
    end

    test "uses cache for previously translated texts" do
      # Pre-cache one translation
      assert {:ok, _} = Translation.translate("Hello", "es")

      # Make adapter fail
      Process.put(:test_adapter_fail, true)

      # Batch with one cached and two new (new ones will fail)
      texts = ["Hello", "World", "Test"]

      # This will fail because World and Test aren't cached
      assert {:error, _} = Translation.translate_batch(texts, nil, "es")
    end

    test "returns all cached results when all are cached" do
      # Pre-cache all translations
      assert {:ok, _} = Translation.translate("Hello", "es")
      assert {:ok, _} = Translation.translate("World", "es")

      # Make adapter fail
      Process.put(:test_adapter_fail, true)

      # All cached - should succeed
      texts = ["Hello", "World"]
      assert {:ok, results} = Translation.translate_batch(texts, nil, "es")
      assert length(results) == 2
    end
  end

  describe "detect_language/1" do
    test "detects language of text" do
      assert {:ok, %{language: "fr", confidence: confidence}} =
               Translation.detect_language("bonjour")

      assert confidence > 0
    end

    test "returns error for empty text" do
      assert {:error, :empty_text} = Translation.detect_language("")
    end
  end

  describe "adapters/0" do
    test "returns available adapters" do
      adapters = Translation.adapters()
      assert is_list(adapters)
    end

    test "filters out unavailable adapters" do
      Process.put(:test_adapter_unavailable, true)
      adapters = Translation.adapters()
      refute Bonfire.Translation.TestAdapter in adapters
    end
  end

  describe "supports_pair?/2" do
    test "returns true for supported language pair" do
      assert Translation.supports_pair?("en", "es")
    end

    test "returns false for unsupported language pair" do
      refute Translation.supports_pair?("en", "xx")
    end
  end

  describe "language code normalization" do
    test "handles uppercase language codes" do
      assert {:ok, _} = Translation.translate("Hello", "EN", "ES", [])
    end

    test "handles atom language codes" do
      assert {:ok, _} = Translation.translate("Hello", :en, :es, [])
    end
  end
end
