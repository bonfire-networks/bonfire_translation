defmodule Bonfire.Translation.Behaviour do
  @moduledoc """
  Behaviour for translation adapters.

  Adapters must implement these callbacks to provide translation services.
  All language codes should be normalized to lowercase ISO 639-1 format (e.g., "en", "fr", "de").

  ## Usage

  To create a translation adapter, implement this behaviour:

      defmodule MyApp.Translation.MyAdapter do
        @behaviour Bonfire.Translation.Behaviour

        @impl true
        def translate(text, source_lang, target_lang, opts) do
          # ...
        end

        # ... other callbacks
      end
  """

  @behaviour Bonfire.Common.ExtensionBehaviour

  @doc "Declares a translation adapter module"
  @callback translation_adapter() :: atom()

  @doc """
  Translates text to the target language, auto-detecting the source language.
  """
  @callback translate(text :: String.t(), target_lang :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Translates text from source language to target language.
  Pass `nil` as source_lang to auto-detect.
  """
  @callback translate(
              text :: String.t(),
              source_lang :: String.t() | nil,
              target_lang :: String.t(),
              opts :: keyword()
            ) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Translates multiple texts at once. More efficient for batch operations.
  """
  @callback translate_batch(
              texts :: [String.t()],
              source_lang :: String.t() | nil,
              target_lang :: String.t(),
              opts :: keyword()
            ) :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  Detects the language of the given text.
  Returns the detected language code and confidence score (0.0 to 1.0).
  """
  @callback detect_language(text :: String.t()) ::
              {:ok, %{language: String.t(), confidence: float()}} | {:error, term()}

  @doc """
  Returns list of supported languages with their available target languages.
  """
  @callback supported_languages() ::
              {:ok, [%{code: String.t(), name: String.t(), targets: [String.t()]}]}
              | {:error, term()}

  @doc """
  Checks if translation between source and target language is supported.
  """
  @callback supports_pair?(source_lang :: String.t(), target_lang :: String.t()) :: boolean()

  @doc """
  Checks if the translation service is available and configured.
  """
  @callback available?() :: boolean()

  @optional_callbacks [
    translation_adapter: 0,
    translate: 3,
    translate_batch: 4,
    detect_language: 1,
    supported_languages: 0,
    supports_pair?: 2,
    available?: 0
  ]

  @doc """
  Returns all registered translation adapter modules.
  """
  @impl Bonfire.Common.ExtensionBehaviour
  def modules do
    Bonfire.Common.ExtensionBehaviour.behaviour_modules(__MODULE__)
  end
end
