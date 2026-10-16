defmodule MeerkatWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :meerkat

  # `signing_salt` is static because no real session data is stored —
  # meerkat is single-user local and doesn't authenticate humans.
  @session_options [
    store: :cookie,
    signing_salt: "Nep9J65z",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {__MODULE__, :socket_session_options, []}]],
    longpoll: [connect_info: [session: {__MODULE__, :socket_session_options, []}]]

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
  plug :session
  plug MeerkatWeb.Router

  # Each review signs its cookie with its own secret, and browsers don't
  # scope cookies by port. One cookie name for every review would let
  # loading another review overwrite this one's cookie, so a tab rejoining
  # after a restart could not verify it and would fully reload instead.
  @doc false
  def session_options(port), do: [{:key, "_meerkat_key_#{port}"} | @session_options]

  @doc false
  def socket_session_options(server_info \\ &server_info/1) do
    {:ok, {_ip, port}} = server_info.(:http)
    session_options(port)
  end

  defp session(conn, _opts),
    do: Plug.Session.call(conn, Plug.Session.init(session_options(conn.port)))
end
