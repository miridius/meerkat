defmodule MeerkatWeb.Loopback do
  @moduledoc """
  Loopback-only guard. `origin?/1` backs the LiveView socket's
  `:check_origin`; the plug (`call/2`) rejects HTTP requests whose
  `Host` isn't loopback. Together they keep a rebound attacker domain
  from reading the local diff endpoint.
  """

  import Plug.Conn

  @loopback_hosts ~w(127.0.0.1 localhost ::1)

  @doc "True iff `uri`'s host is loopback. Used as the endpoint `:check_origin` MFA."
  @spec origin?(URI.t()) :: boolean()
  def origin?(%URI{host: host}), do: host in @loopback_hosts

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{host: host} = conn, _opts) do
    if host in @loopback_hosts do
      conn
    else
      conn
      |> send_resp(403, "meerkat serves loopback clients only")
      |> halt()
    end
  end
end
