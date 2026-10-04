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
  alias Bonfire.Common.Settings
  import Bonfire.UI.Common.Modularity.DeclareHelpers

  declare_settings(:input, l("LibreTranslate API Key"),
    keys: [Bonfire.Translation.LibreTranslate, :api_key],
    description: l("Enter your API key for LibreTranslate, if required")
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
    with {:ok, server} <- server_opts(opts) do
      source_lang = source_lang || "auto"

      opts =
        opts
        |> Keyword.put(:format, normalize_format(opts[:format]))
        |> Keyword.merge(server)

      do_translate(text, source_lang, target_lang, opts)
    end
  end

  @impl true
  def translate_batch(texts, source_lang, target_lang, opts) do
    source_lang = source_lang || "auto"

    opts =
      opts
      |> Keyword.put(:format, normalize_format(opts[:format]))

    # LibreTranslate doesn't have native batch, so we translate sequentially
    Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, acc} ->
      case translate(text, source_lang, target_lang, opts) do
        {:ok, translated} -> {:cont, {:ok, acc ++ [translated]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp do_translate(text, source_lang, target_lang, opts) do
    case LibreTranslate.Translator.translate(text, source_lang, target_lang, opts) do
      {:ok, %{"translatedText" => translated}} ->
        {:ok, translated}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def detect_language(text, opts) do
    with {:ok, server} <- server_opts(opts),
         {:ok, [%{"language" => lang, "confidence" => confidence} | _]} <-
           LibreTranslate.Detector.detect(text, server) do
      {:ok, %{language: normalize_lang_code(lang), confidence: confidence / 100.0}}
    else
      {:ok, []} ->
        {:error, :no_language_detected}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def supported_languages(opts) do
    with {:ok, server} <- server_opts(opts) do
      server_languages(server)
    end
  end

  defp server_languages(server) do
    case LibreTranslate.Language.get_languages(server) do
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
  def supports_pair?(source_lang, target_lang, opts) do
    case supported_languages(opts) do
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
  def available?(opts) do
    case server_opts(opts) do
      {:ok, server} -> LibreTranslate.Health.healthy?(server) || false
      _refused -> false
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

  # The server and key for this request: the user's own if they set one, otherwise the admin's. They're passed with each request rather than set globally, so one user's choice never applies to anyone else's translations. The admin's server may be on a private address (e.g. in Docker), but a user's own must be public.
  defp server_opts(opts) do
    config = Settings.get(__MODULE__, [], opts)

    with :ok <- check_users_server(config[:base_url], Config.get([__MODULE__], [])[:base_url]) do
      {:ok,
       [base_url: config[:base_url], api_key: config[:api_key]]
       |> Enum.reject(fn {_, value} -> is_nil(value) end)}
    end
  end

  defp check_users_server(nil, _admins), do: :ok
  defp check_users_server(admins, admins), do: :ok
  defp check_users_server(users_own, _admins), do: Bonfire.Common.HTTP.SSRF.check(users_own)
end
