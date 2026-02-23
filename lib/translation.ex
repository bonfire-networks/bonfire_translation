defmodule Bonfire.Translation do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  use Bonfire.Common.Config
  use Bonfire.Common.Localise
  import Untangle
  import Bonfire.Common.Modularity.DeclareHelpers

  declare_extension(
    "Bonfire Translation",
    icon: "bi:translate",
    description: l("An extension that provides translation capabilities using various adapters.")
  )

  @moduledoc """
  Translation context module that routes to appropriate adapters with caching.

  This module:
  - Routes translation requests to the appropriate adapter based on language pair support
  - Caches language detection and translation results
  - Falls back to next adapter on failure (max 2 attempts)
  - Normalizes language codes to lowercase ISO 639-1

  ## Configuration

      config :bonfire_translation, Bonfire.Translation,
        default_target_language: "en",
        cache_ttl_days: 7

      # Per-adapter priority (lower = higher priority, default 0)
      config :bonfire_translation, Bonfire.Translation.LibreTranslate,
        base_url: "https://libretranslate.example.com",
        priority: 1

      config :bonfire_translation, Bonfire.Translation.DeepL,
        api_key: "...",
        priority: 2
  """

  use Bonfire.Common.Utils
  alias Bonfire.Common.Cache
  alias Bonfire.Common.Config
  alias Bonfire.Common.Text
  alias Bonfire.Translation.Behaviour

  @cache_prefix "translation::"
  @default_ttl_days 15
  @max_attempts 2

  # --- Public API ---

  @doc """
  Translates text to the target language, auto-detecting the source language.

  ## Options
    * `:format` - `:text` or `:html` (default: `:text`)
    * `:adapter` - Force a specific adapter module
    * Other options are passed through to the adapter

  ## Examples

      iex> Bonfire.Translation.translate("Bonjour!", "en")
      {:ok, "Hello!"}
  """
  def translate(text, target_lang, opts \\ []) do
    translate(text, nil, target_lang, opts)
  end

  @doc """
  Translates text from source language to target language.

  Pass `nil` as source_lang to auto-detect.
  """
  def translate(text, source_lang, target_lang, opts)

  def translate(text, source_lang, target_lang, opts)
      when is_binary(text) and byte_size(text) > 0 do
    target = normalize_lang_code(target_lang)
    source = if source_lang, do: normalize_lang_code(source_lang), else: nil
    text_hash = hash_text(text)

    cache_key = translation_cache_key(text_hash, source, target)

    case Cache.get!(cache_key) do
      nil ->
        do_translate(text, source, target, text_hash, opts)

      cached ->
        debug("Translation cache hit for #{text_hash}")
        {:ok, cached}
    end
  end

  def translate(_, _, _, _), do: {:error, :empty_text}

  @doc """
  Translates multiple texts at once.

  Checks cache for each text, only sends uncached texts to the API,
  then returns all results in order.
  """
  def translate_batch(texts, source_lang, target_lang, opts \\ [])
      when is_list(texts) do
    target = normalize_lang_code(target_lang)
    source = if source_lang, do: normalize_lang_code(source_lang), else: nil

    {cached_results, uncached} =
      texts
      |> Enum.with_index()
      |> Enum.reduce({%{}, []}, fn {text, idx}, {cached, uncached_acc} ->
        text_hash = hash_text(text)
        cache_key = translation_cache_key(text_hash, source, target)

        case Cache.get!(cache_key) do
          nil ->
            {cached, [{idx, text, text_hash} | uncached_acc]}

          result ->
            {Map.put(cached, idx, result), uncached_acc}
        end
      end)

    uncached = Enum.reverse(uncached)

    if Enum.empty?(uncached) do
      {:ok, Enum.map(0..(length(texts) - 1), &Map.get(cached_results, &1))}
    else
      uncached_texts = Enum.map(uncached, fn {_, text, _} -> text end)

      case do_translate_batch(uncached_texts, source, target, opts) do
        {:ok, translated} ->
          Enum.zip(uncached, translated)
          |> Enum.each(fn {{_idx, _text, text_hash}, translation} ->
            cache_key = translation_cache_key(text_hash, source, target)
            cache_translation(cache_key, translation)
          end)

          new_results =
            Enum.zip(uncached, translated)
            |> Enum.reduce(cached_results, fn {{idx, _, _}, translation}, acc ->
              Map.put(acc, idx, translation)
            end)

          {:ok, Enum.map(0..(length(texts) - 1), &Map.get(new_results, &1))}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Detects the language of the given text with caching.
  """
  def detect_language(text) when is_binary(text) and byte_size(text) > 0 do
    text_hash = hash_text(text)
    cache_key = language_cache_key(text_hash)

    case Cache.get!(cache_key) do
      nil ->
        case do_detect_language(text) do
          {:ok, result} = success ->
            cache_language(cache_key, result.language)
            success

          error ->
            error
        end

      cached_lang ->
        debug("Language cache hit for #{text_hash}: #{cached_lang}")
        {:ok, %{language: cached_lang, confidence: 1.0}}
    end
  end

  def detect_language(_), do: {:error, :empty_text}

  @doc """
  Returns supported languages from all available adapters, merged and cached.
  """
  def supported_languages do
    Cache.maybe_apply_cached({__MODULE__, :do_get_supported_languages}, [], expire: ttl_ms())
  end

  @doc false
  def do_get_supported_languages do
    adapters()
    |> Enum.reduce({:ok, []}, fn adapter, {:ok, acc} ->
      case safe_call(adapter, :supported_languages, []) do
        {:ok, languages} -> {:ok, acc ++ languages}
        _ -> {:ok, acc}
      end
    end)
    |> case do
      {:ok, languages} ->
        {:ok, Enum.uniq_by(languages, & &1.code)}
    end
  end

  @doc """
  Checks if any adapter supports the given language pair.
  """
  def supports_pair?(source_lang, target_lang) do
    source = normalize_lang_code(source_lang)
    target = normalize_lang_code(target_lang)

    Enum.any?(adapters(), fn adapter ->
      safe_call(adapter, :supports_pair?, [source, target]) == true
    end)
  end

  @doc "Checks if any translation adapter has config (API key or base URL) set at instance level. Lightweight, no HTTP calls."
  def any_adapter_configured? do
    Behaviour.modules()
    |> Enum.any?(fn adapter ->
      config = Config.get(adapter, [])
      not is_nil(config[:api_key]) or not is_nil(config[:base_url])
    end)
  end

  @doc """
  Returns list of configured and available adapters, ordered by priority.

  Adapters are sorted by their `:priority` config value (lower = higher priority).
  Default priority is 0.
  """
  def adapters do
    # Allow process-level override for testing
    case ProcessTree.get(:bonfire_translation_adapters) do
      adapters_list when is_list(adapters_list) and adapters_list != [] ->
        adapters_list
        |> debug("Using process-level translation adapters")
        |> Enum.filter(&adapter_available?/1)

      _ ->
        # Get all registered adapters from the behaviour
        Behaviour.modules()
        |> Enum.filter(&adapter_available?/1)
        |> Enum.sort_by(&adapter_priority/1)
    end
  end

  defp adapter_priority(adapter) do
    Config.get([adapter, :priority], 0)
  end

  # --- Private ---

  defp do_translate(text, source_lang, target_lang, text_hash, opts) do
    adapters_list = find_adapters_for_pair(source_lang, target_lang, opts)

    try_adapters(adapters_list, @max_attempts, fn adapter ->
      case adapter.translate(text, source_lang, target_lang, opts) do
        {:ok, translated} = success ->
          cache_key = translation_cache_key(text_hash, source_lang, target_lang)
          cache_translation(cache_key, translated)
          success

        error ->
          error
      end
    end)
  end

  defp do_translate_batch(texts, source_lang, target_lang, opts) do
    adapters_list = find_adapters_for_pair(source_lang, target_lang, opts)

    try_adapters(adapters_list, @max_attempts, fn adapter ->
      if function_exported?(adapter, :translate_batch, 4) do
        adapter.translate_batch(texts, source_lang, target_lang, opts)
      else
        Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, acc} ->
          case adapter.translate(text, source_lang, target_lang, opts) do
            {:ok, translated} -> {:cont, {:ok, acc ++ [translated]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
      end
    end)
  end

  defp do_detect_language(text) do
    adapters()
    |> try_adapters(@max_attempts, fn adapter ->
      if function_exported?(adapter, :detect_language, 1) do
        adapter.detect_language(text)
      else
        {:error, :not_supported}
      end
    end)
  end

  defp find_adapters_for_pair(source_lang, target_lang, opts) do
    case opts[:adapter] do
      nil ->
        adapters()
        |> Enum.filter(fn adapter ->
          source_lang == nil or
            safe_call(adapter, :supports_pair?, [source_lang, target_lang]) == true
        end)
        |> case do
          [] -> adapters()
          found -> found
        end

      adapter when is_atom(adapter) ->
        [adapter]
    end
  end

  defp try_adapters([], _max_attempts, _fun) do
    {:error, :no_adapters_available}
  end

  defp try_adapters(adapters_list, max_attempts, fun) do
    adapters_list
    |> Enum.take(max_attempts)
    |> Enum.reduce_while({:error, :no_adapters_tried}, fn adapter, _acc ->
      case fun.(adapter) do
        {:ok, _} = success ->
          {:halt, success}

        {:error, reason} = error ->
          warn("Adapter #{inspect(adapter)} failed: #{inspect(reason)}")
          {:cont, error}
      end
    end)
  end

  defp adapter_available?(adapter) do
    if function_exported?(adapter, :available?, 0) do
      safe_call(adapter, :available?, []) == true
    else
      Code.ensure_loaded?(adapter)
    end
  end

  defp safe_call(module, fun, args) do
    apply(module, fun, args)
  rescue
    e ->
      warn("Error calling #{inspect(module)}.#{fun}: #{inspect(e)}")
      {:error, e}
  end

  # --- Caching ---

  defp translation_cache_key(text_hash, source_lang, target_lang) do
    source = source_lang || "auto"
    "#{@cache_prefix}t::#{source}::#{target_lang}::#{text_hash}"
  end

  defp language_cache_key(text_hash) do
    "#{@cache_prefix}lang::#{text_hash}"
  end

  defp cache_translation(key, translation) do
    Cache.put(key, translation, expire: ttl_ms())
  end

  defp cache_language(key, language) do
    Cache.put(key, language, expire: ttl_ms())
  end

  defp ttl_ms do
    days = Config.get([__MODULE__, :cache_ttl_days], @default_ttl_days)
    days * 24 * 60 * 60 * 1000
  end

  # --- Utilities ---

  defp hash_text(text) do
    Text.hash(text)
  end

  defp normalize_lang_code(code) when is_binary(code) do
    code |> String.downcase() |> String.slice(0, 2)
  end

  defp normalize_lang_code(code) when is_atom(code) and not is_nil(code) do
    code |> Atom.to_string() |> normalize_lang_code()
  end

  defp normalize_lang_code(nil), do: nil
end
