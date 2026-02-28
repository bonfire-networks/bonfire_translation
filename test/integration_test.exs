defmodule Bonfire.Translation.IntegrationTest do
  @moduledoc """
  Integration tests for translation adapters.

  These tests require a configured and available translation service.

  To run these tests:

    # With LibreTranslate:
    LIBRETRANSLATE_URL=http://localhost:5000 mix test  --only integration

    # With DeepL:
    DEEPL_API_KEY=your-api-key mix test  --only integration

    # Or force a specific adapter:
    TRANSLATION_ADAPTER=Bonfire.Translation.TestAdapter mix test  --only integration
  """

  use ExUnit.Case, async: false

  alias Bonfire.Translation
  use Bonfire.Common.Config
  alias Bonfire.Common.Cache

  @moduletag :integration

  setup do
    # Clear cache before each test
    Cache.remove_all()

    # Configure adapters from env vars if provided
    configure_from_env()

    # Check if any adapter is available
    case Translation.adapters() do
      [] ->
        {:skip, "No translation adapters available. Configure LibreTranslate or DeepL."}

      adapters ->
        {:ok, adapters: adapters, adapter: hd(adapters)}
    end
  end

  defp configure_from_env do
    # Configure LibreTranslate from env
    if url = System.get_env("LIBRETRANSLATE_URL") do
      Process.put([:bonfire_translation, Bonfire.Translation.LibreTranslate], base_url: url)
      Process.put(:bonfire_translation_adapters, [Bonfire.Translation.LibreTranslate])
    end

    # Configure DeepL from env
    if key = System.get_env("DEEPL_API_KEY") do
      Process.put([:bonfire_translation, Bonfire.Translation.DeepL], api_key: key)
      Process.put(:bonfire_translation_adapters, [Bonfire.Translation.DeepL])
    end

    # Force specific adapter if requested
    if adapter_name = System.get_env("TRANSLATION_ADAPTER") do
      if adapter = Bonfire.Common.Types.maybe_to_module(adapter_name) do
        Process.put(:bonfire_translation_adapters, [adapter])
      end
    end
  end

  describe "adapters/0" do
    test "returns at least one available adapter", %{adapters: adapters} do
      assert length(adapters) > 0
      assert Enum.all?(adapters, &is_atom/1)
    end
  end

  describe "supported_languages/0" do
    test "returns list of supported languages" do
      assert {:ok, languages} = Translation.supported_languages()
      assert is_list(languages)
      assert length(languages) > 0

      # Check structure
      first = hd(languages)
      assert Map.has_key?(first, :code)
      assert Map.has_key?(first, :name)
      assert Map.has_key?(first, :targets)

      # Language codes should be lowercase
      assert first.code == String.downcase(first.code)
    end
  end

  describe "supports_pair?/2" do
    test "returns true for common language pairs" do
      # These pairs should be supported by most translation services
      assert Translation.supports_pair?("en", "fr")
      assert Translation.supports_pair?("en", "es")
      assert Translation.supports_pair?("fr", "en")
    end

    test "handles uppercase language codes" do
      assert Translation.supports_pair?("EN", "FR")
    end
  end

  describe "detect_language/1" do
    test "detects French text" do
      assert {:ok, %{language: lang, confidence: confidence}} =
               Translation.detect_language("Bonjour, comment allez-vous aujourd'hui?")

      assert lang == "fr"
      assert is_float(confidence)
      assert confidence > 0
    end

    test "detects English text" do
      assert {:ok, %{language: lang, confidence: confidence}} =
               Translation.detect_language("Hello, how are you doing today?")

      assert lang == "en"
      assert is_float(confidence)
      assert confidence > 0
    end

    test "detects Spanish text" do
      assert {:ok, %{language: lang, confidence: _}} =
               Translation.detect_language("Hola, ¿cómo estás hoy?")

      assert lang == "es"
    end

    test "caches detection results" do
      text = "Hola, ¿cómo estás hoy?"

      # First call
      assert {:ok, %{language: "es"}} = Translation.detect_language(text)

      # Second call should use cache (we can't easily verify this without checking internals, but at least verify it returns same result)
      assert {:ok, %{language: "es"}} = Translation.detect_language(text)
    end
  end

  describe "translate/3" do
    test "translates French to English" do
      assert {:ok, translated} = Translation.translate("Bonjour le monde", "en")

      assert is_binary(translated)
      assert String.length(translated) > 0
      assert String.downcase(translated) =~ ~r/hello|good|hi/
    end

    test "translates Spanish to English" do
      assert {:ok, translated} = Translation.translate("Hola mundo", "en")

      assert is_binary(translated)
      assert String.downcase(translated) =~ ~r/hello|world/
    end

    test "caches translation results" do
      text = "Guten Morgen"
      target = "en"

      # First call
      assert {:ok, first_result} = Translation.translate(text, target)

      # Second call should use cache
      assert {:ok, second_result} = Translation.translate(text, target)

      assert first_result == second_result
    end
  end

  describe "translate/4" do
    test "translates with explicit source language" do
      assert {:ok, translated} = Translation.translate("Bonjour", "fr", "en", [])

      assert is_binary(translated)
      assert String.downcase(translated) =~ ~r/hello|good|hi/
    end

    test "translates with auto-detect (nil source)" do
      assert {:ok, translated} = Translation.translate("Bonjour", nil, "en", [])

      assert is_binary(translated)
      assert String.downcase(translated) =~ ~r/hello|good|hi/
    end

    test "handles uppercase language codes" do
      assert {:ok, translated} = Translation.translate("Bonjour", "FR", "EN", [])

      assert is_binary(translated)
    end

    test "handles atom language codes" do
      assert {:ok, translated} = Translation.translate("Bonjour", :fr, :en, [])

      assert is_binary(translated)
    end
  end

  describe "translate/4 with HTML format" do
    test "preserves HTML structure when format is :html" do
      html_text = "<p>Bonjour <strong>le monde</strong></p>"

      assert {:ok, translated} = Translation.translate(html_text, "fr", "en", format: :html)

      assert is_binary(translated)
      assert translated =~ "<p>"
      assert translated =~ "</p>"
      assert translated =~ "<strong>"
      assert translated =~ "</strong>"
    end

    test "handles nested HTML elements" do
      html_text = "<div><p>Bonjour</p><p>Au revoir</p></div>"

      assert {:ok, translated} = Translation.translate(html_text, "fr", "en", format: :html)

      assert translated =~ "<div>"
      assert translated =~ "</div>"
      assert translated =~ "<p>"
    end
  end

  describe "translate_batch/4" do
    test "translates multiple texts" do
      texts = ["Bonjour", "Au revoir", "Merci"]

      assert {:ok, results} = Translation.translate_batch(texts, "fr", "en")

      assert is_list(results)
      assert length(results) == 3
      assert Enum.all?(results, &is_binary/1)
    end

    test "maintains order of translations" do
      texts = ["Un", "Deux", "Trois"]

      assert {:ok, [first, second, third]} = Translation.translate_batch(texts, "fr", "en")

      # Results should correspond to input order
      assert String.downcase(first) =~ ~r/one|a/
      assert String.downcase(second) =~ ~r/two/
      assert String.downcase(third) =~ ~r/three/
    end

    test "uses cache for previously translated texts" do
      # Pre-translate one text
      assert {:ok, _} = Translation.translate("Bonjour", "fr", "en", [])

      # Batch with that text and others
      texts = ["Bonjour", "Salut"]

      assert {:ok, results} = Translation.translate_batch(texts, "fr", "en")
      assert length(results) == 2
    end
  end

  describe "error handling" do
    test "returns error for empty text" do
      assert {:error, :empty_text} = Translation.translate("", "en")
    end

    test "returns error for nil text" do
      assert {:error, :empty_text} = Translation.translate(nil, "en")
    end
  end
end
