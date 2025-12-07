defmodule Bonfire.Translation.TestAdapter do
  @moduledoc """
  A test adapter for translation that returns predictable responses.

  Configure via process dictionary:
    - `:test_adapter_fail` - set to `true` to simulate failures
    - `:test_adapter_unavailable` - set to `true` to mark adapter as unavailable

  ## Examples

      # In your test:
      Process.put(:test_adapter_fail, true)
      assert {:error, :simulated_failure} = Bonfire.Translation.translate("hello", "es")
  """

  @behaviour Bonfire.Translation.Behaviour

  @impl true
  def translation_adapter, do: __MODULE__

  @impl true
  def translate(text, target_lang, opts) do
    translate(text, nil, target_lang, opts)
  end

  @impl true
  def translate(text, source_lang, target_lang, _opts) do
    if Process.get(:test_adapter_fail) do
      {:error, :simulated_failure}
    else
      source = source_lang || "auto"
      {:ok, "[#{source}->#{target_lang}] #{text}"}
    end
  end

  @impl true
  def translate_batch(texts, source_lang, target_lang, opts) do
    if Process.get(:test_adapter_fail) do
      {:error, :simulated_failure}
    else
      results =
        Enum.map(texts, fn text ->
          {:ok, translated} = translate(text, source_lang, target_lang, opts)
          translated
        end)

      {:ok, results}
    end
  end

  @impl true
  def detect_language(text) do
    if Process.get(:test_adapter_fail) do
      {:error, :simulated_failure}
    else
      text = String.downcase(text)
      # Simple heuristic for testing - detect based on common words
      lang =
        cond do
          String.contains?(text, ["bonjour", "merci", "salut"]) -> "fr"
          String.contains?(text, ["hola", "gracias", "buenos"]) -> "es"
          true -> "en"
        end

      {:ok, %{language: lang, confidence: 0.95}}
    end
  end

  @impl true
  def supported_languages do
    {:ok,
     [
       %{code: "en", name: "English", targets: ["fr", "es"]},
       %{code: "fr", name: "French", targets: ["en", "es"]},
       %{code: "es", name: "Spanish", targets: ["en", "fr"]}
     ]}
  end

  @impl true
  def supports_pair?(source_lang, target_lang) do
    case supported_languages() do
      {:ok, languages} ->
        Enum.any?(languages, fn lang ->
          lang.code == source_lang and target_lang in lang.targets
        end)

      _ ->
        false
    end
  end

  @impl true
  def available? do
    not Process.get(:test_adapter_unavailable, false)
  end
end
