defmodule MeerkatWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :meerkat

  # `signing_salt` is static because no real session data is stored —
  # meerkat is single-user local and doesn't authenticate humans.
  @session_options [
    store: :cookie,
    key: "_meerkat_key",
    signing_salt: "Nep9J65z",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :meerkat,
    gzip: not code_reloading?,
    only: MeerkatWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug MeerkatWeb.Router
end
