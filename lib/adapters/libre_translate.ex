defmodule Bonfire.Translation.LibreTranslate do
  @moduledoc """
  Translation adapter for LibreTranslate.

  ## Configuration

      config :bonfire_translation, Bonfire.Translation.LibreTranslate,
        base_url: "https://libretranslate.example.com",
        api_key: "your-api-key"
  """

  @behaviour Bonfire.Translation.Behaviour

  use Bonfire.Common.Utils
  alias Bonfire.Common.Config

  @impl true
  def translation_adapter, do: __MODULE__

  @impl true
  def translate(text, target_lang, opts) do
    translate(text, nil, target_lang, opts)
  end

  @impl true
  def translate(text, source_lang, target_lang, opts) do
    maybe_configure()

    source = source_lang || "auto"
    format = normalize_format(opts[:format])

    lib_opts =
      opts
      |> Keyword.delete(:format)
      |> Keyword.put(:format, format)

    case LibreTranslate.Translator.translate(text, source, target_lang, lib_opts) do
      {:ok, %{"translatedText" => translated}} ->
        {:ok, translated}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def translate_batch(texts, source_lang, target_lang, opts) do
    # LibreTranslate doesn't have native batch, so we translate sequentially
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

    case LibreTranslate.Detector.detect(text) do
      {:ok, [%{"language" => lang, "confidence" => confidence} | _]} ->
        {:ok, %{language: normalize_lang_code(lang), confidence: confidence / 100.0}}

      {:ok, []} ->
        {:error, :no_language_detected}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def supported_languages do
    maybe_configure()

    case LibreTranslate.Language.get_languages() do
      {:ok, languages} ->
        normalized =
          Enum.map(languages, fn %{"code" => code, "name" => name, "targets" => targets} ->
            %{
              code: normalize_lang_code(code),
              name: name,
              targets: Enum.map(targets, &normalize_lang_code/1)
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
    maybe_configure()

    result = LibreTranslate.Health.healthy?()

    case result do
      true -> true
      _ -> false
    end
  rescue
    e ->
      false
  end

  # Normalize language code to lowercase ISO 639-1
  defp normalize_lang_code(code) when is_binary(code) do
    code |> String.downcase() |> String.slice(0, 2)
  end

  defp normalize_lang_code(code), do: code

  # Normalize format option
  defp normalize_format(:html), do: "html"
  defp normalize_format("html"), do: "html"
  defp normalize_format(_), do: "text"

  defp maybe_configure do
    config = Config.get(__MODULE__, [])

    if config[:base_url] do
      LibreTranslate.set_base_url(config[:base_url])
    end

    if config[:api_key] do
      LibreTranslate.set_api_key(config[:api_key])
    end

    config
  end
end
