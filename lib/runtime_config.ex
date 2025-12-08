defmodule Bonfire.Translation.RuntimeConfig do
  use Bonfire.Common.Localise
  import Bonfire.UI.Common.Modularity.DeclareHelpers

  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  declare_settings(:input, l("LibreTranslate URL"),
    keys: [Bonfire.Translation.LibreTranslate, :base_url],
    description: l("Enter the URL for the LibreTranslate service you are using")
    # scope: :user
  )

  @doc """
  Sets runtime configuration for the extension (typically by reading ENV variables).
  """
  def config do
    import Config

    # config :bonfire_translation,
    #   modularity: System.get_env("ENABLE_bonfire_translation") || :disabled
  end
end
