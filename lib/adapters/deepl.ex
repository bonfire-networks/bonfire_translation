defmodule Bonfire.Translation.DeepL do
  @moduledoc """
  Translation adapter for DeepL.

  ## Configuration

      config :bonfire_translation, Bonfire.Translation.DeepL,
        api_key: "your-api-key"
  """

  @behaviour Bonfire.Translation.Behaviour

  use Bonfire.Common.Utils
  alias Bonfire.Common.Config
  import Bonfire.UI.Common.Modularity.DeclareHelpers

  declare_settings(:input, l("DeepL API Key"),
    keys: [Bonfire.Translation.DeepL, :api_key],
    description: l("Enter your API key for DeepL, if using DeepL as a translation service")
    # scope: :user
  )

  @impl true
  def translation_adapter, do: __MODULE__

  @impl true
  def translate(text, target_lang, opts) do
    translate(text, nil, target_lang, opts)
  end

  @impl true
  def translate(text, source_lang, target_lang, opts) do
    maybe_configure()

    lib_opts =
      opts
      |> normalize_opts()
      |> maybe_add_source_lang(source_lang)

    case Deepl.Translator.translate(text, normalize_lang_code_for_api(target_lang), lib_opts) do
      {:ok, %{"translations" => [%{"text" => translated} | _]}} ->
        {:ok, translated}

      {:ok, %{"message" => error}} ->
        {:error, error}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def translate_batch(texts, source_lang, target_lang, opts) do
    Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, acc} ->
      case translate(text, source_lang, target_lang, opts) do
        {:ok, translated} -> {:cont, {:ok, acc ++ [translated]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @impl true
  def detect_language(text) do
    maybe_configure()

    case Deepl.Translator.translate(text, "EN") do
      {:ok, %{"translations" => [%{"detected_source_language" => lang} | _]}} ->
        {:ok, %{language: normalize_lang_code(lang), confidence: 1.0}}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def supported_languages do
    maybe_configure()

    case Deepl.Language.get_languages() do
      {:ok, languages} ->
        # DeepL returns flat list, all languages can translate to all others
        codes =
          Enum.map(languages, fn %{"language" => code} ->
            normalize_lang_code(code)
          end)

        normalized =
          Enum.map(languages, fn %{"language" => code, "name" => name} ->
            %{
              code: normalize_lang_code(code),
              name: name,
              targets: codes -- [normalize_lang_code(code)]
            }
          end)

        {:ok, normalized}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def supports_pair?(source_lang, target_lang) do
    case supported_languages() do
      {:ok, languages} ->
        source = normalize_lang_code(source_lang)
        target = normalize_lang_code(target_lang)

        Enum.any?(languages, fn lang ->
          lang.code == source and target in lang.targets
        end)

      _ ->
        false
    end
  end

  @impl true
  def available? do
    config = Config.get(__MODULE__, [])
    not is_nil(config[:api_key])
  end

  # Normalize language code to lowercase ISO 639-1
  defp normalize_lang_code(code) when is_binary(code) do
    code |> String.downcase() |> String.slice(0, 2)
  end

  defp normalize_lang_code(code), do: code

  # DeepL expects uppercase language codes
  defp normalize_lang_code_for_api(code) when is_binary(code) do
    String.upcase(code)
  end

  defp normalize_lang_code_for_api(code), do: code

  # Normalize our common options to DeepL-specific options
  defp normalize_opts(opts) do
    opts
    |> Keyword.delete(:format)
    |> maybe_add_tag_handling(opts[:format])
  end

  defp maybe_add_tag_handling(opts, :html), do: Keyword.put(opts, :tag_handling, "html")
  defp maybe_add_tag_handling(opts, "html"), do: Keyword.put(opts, :tag_handling, "html")
  defp maybe_add_tag_handling(opts, _), do: opts

  defp maybe_add_source_lang(opts, nil), do: opts

  defp maybe_add_source_lang(opts, source_lang) do
    Keyword.put(opts, :source_lang, normalize_lang_code_for_api(source_lang))
  end

  defp maybe_configure do
    config = Config.get(__MODULE__, [])

    if config[:api_key] do
      Deepl.set_api_key(config[:api_key])
    end
  end
end
