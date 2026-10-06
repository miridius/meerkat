import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :meerkat, MeerkatWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "QH2P7vjHF5LPC+1k6/PpILvkFW4S5T2hkeX7qhItS0OY+EkSGW1UHYC0KAzQDKE6",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
