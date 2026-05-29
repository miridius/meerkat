import Config

# Production runs CLI-style: SSR off (no NodeJS overhead at startup).
# If we ever ship a hosted multi-tenant meerkat, flip this to NodeJS
# and add the supervisor to lib/meerkat/application.ex.
config :live_svelte, ssr: false

# Vite-built manifest tracks the digested filenames. PhoenixVite's
# components helper reads it; the Plug.Static raise_on_missing_only
# guard catches drift.
config :meerkat, MeerkatWeb.Endpoint, []

# Do not print debug messages in production
config :logger, level: :info
