import Config

# Dev launcher path (`bin/meerkat-beam` with MIX_ENV=dev — installed
# via `scripts/dev-install.sh`).
#
# No vite watcher + no `static_url` host override: assets serve via
# the meerkat endpoint itself out of `priv/static/` (built by the
# pre-flight `bunx vite build` in `bin/meerkat-beam`). The previous
# wiring booted a vite dev server on :5173 and pointed Phoenix at
# it, but `root.html.heex` emits the asset URLs as relative paths
# (`to_url={fn p -> p end}`) — so the browser hit `/@vite/client`
# on the meerkat host (not vite) and the whole page rendered
# unstyled.
#
# Trade-off: no Svelte/CSS HMR. Editing assets needs a meerkat
# restart so the pre-flight rebuilds priv/static/.
#
# `code_reloader: false`: Phoenix's request-time `.ex` recompile
# fights `Meerkat.CLI`'s `Application.put_env` + manual supervisor
# start with a "config files newer than manifests, must restart"
# error on every request. `.ex` edits need a meerkat restart.
config :meerkat, MeerkatWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: {MeerkatWeb.Loopback, :origin?, []},
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "6EItl5mF8sNaSSglxLlSruE7ke+EPHgJ9lxpHgbqWWXe/v/6CkUGTmXjiUyzdeD7"

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
