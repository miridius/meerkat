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

  # The socket reads no session cookie. Each review signs its cookie with
  # its own secret under the one name, and browsers don't scope cookies by
  # port, so after another review loads, a tab's rejoin could not verify
  # the cookie and would fully reload. Meerkat keeps nothing in the session
  # for the socket to check: check_origin refuses non-loopback origins, and
  # a join needs the page's signed LiveView token.
  socket "/live", Phoenix.LiveView.Socket, websocket: true, longpoll: true

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

  # The query-string limit matches the request-line limit set in
  # `Meerkat.CLI`, so an oversized PlantUML `src` reaches the 413.
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    query_string_length: 2 * 1024 * 1024

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug MeerkatWeb.Router
end
