import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

# The CLI controls whether the endpoint binds (Meerkat.CLI sets
# :meerkat, :start_endpoint to true after parsing args). Releases that
# want the server up regardless can also set PHX_SERVER=true.
if System.get_env("PHX_SERVER") do
  config :meerkat, MeerkatWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      :crypto.strong_rand_bytes(48) |> Base.encode64()

  config :meerkat, MeerkatWeb.Endpoint, secret_key_base: secret_key_base
end
