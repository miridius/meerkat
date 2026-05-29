# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

import Config

# LiveSvelte SSR is OFF by default. The CLI binary path renders
# client-side only — initial HTML is the LiveView shell, the Svelte
# component hydrates from props on connect. dev / `iex -S mix
# phx.server` flips this on (Vite-backed SSR) for full hot-reload
# parity. Keeping SSR optional avoids needing NodeJS in the CLI's
# critical path, which matters for the ≤500ms cold-start budget.
config :live_svelte, ssr: false

# phoenix_vite needs to know how to invoke the Vite CLI. The aliases
# in mix.exs reference `phoenix_vite.npm assets install` and
# `phoenix_vite.npm assets exec -- vite build`; this config tells the
# Mix task what cwd / env to run them under.
config :phoenix_vite, PhoenixVite.Npm,
  assets: [args: [], cd: Path.expand("..", __DIR__)],
  vite: [
    args: ~w(exec -- vite),
    cd: Path.expand("../assets", __DIR__),
    env: %{"MIX_BUILD_PATH" => Mix.Project.build_path()}
  ]

config :meerkat,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :meerkat, MeerkatWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MeerkatWeb.ErrorHTML, json: MeerkatWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Meerkat.PubSub,
  live_view: [signing_salt: "ORhdWbtk"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
