import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :meerkat, MeerkatWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "QH2P7vjHF5LPC+1k6/PpILvkFW4S5T2hkeX7qhItS0OY+EkSGW1UHYC0KAzQDKE6",
  # The test endpoint loads no Vite manifest; this fake current asset lets LiveViewTest
  # check that current tracked assets stay put and absent ones redirect.
  cache_static_manifest_latest: %{"assets/app-current.js" => "assets/app-current.js"},
  server: false

# Tests share the machine with other test BEAMs and gates, which can slow
# a real plantuml render or a ReviewServer reply well past what a user's
# machine needs; these bound only a hang.
config :meerkat, plantuml_timeout_ms: 120_000, review_server_call_timeout_ms: 30_000

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
