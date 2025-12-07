ExUnit.start(exclude: [:integration | Bonfire.Common.RuntimeConfig.skip_test_tags()])

# Compile test support files
Code.require_file("support/test_adapter.ex", __DIR__)

Ecto.Adapters.SQL.Sandbox.mode(
  Bonfire.Common.Config.repo(),
  :manual
)
