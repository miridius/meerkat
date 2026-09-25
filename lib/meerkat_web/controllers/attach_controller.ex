defmodule MeerkatWeb.AttachController do
  @moduledoc """
  Endpoints for the caller in `bin/meerkat-attach`. Both require the
  backend's serve token.

  `GET /api/attach?run=<run>` attaches the caller for its run and
  streams newline-terminated frames: `o <line>` is a line for stderr,
  `n <text>` is stderr text with no trailing newline, `k` is a
  heartbeat, and `x <code>` carries the exit code, last. A later
  invocation whose review changed gets 409, and this BEAM halts so it
  can start a fresh one. Once a caller has taken delivery, others get
  503. `quiet=1` skips the banner, for a caller that already printed it.
  A `d` frame ends the stream of a caller displaced by a later
  invocation; that caller exits 1. A caller attaching after a decision
  has been made—whether the outcome is held or a click has happened but
  the outcome has not yet been published—gets no banner and opens no
  browser tab.

  `POST /api/attach/delivered?run=<run>` reports that the caller printed
  the outcome.
  """

  use Phoenix.Controller, formats: []

  import Plug.Conn

  alias Meerkat.{Decision, Persistence, ReviewState}

  # A heartbeat to a caller that has gone fails, which ends its request and detaches it.
  # The deadline runs until that failed heartbeat detaches the caller, so this interval
  # bounds how long it keeps running after the caller dies. At 1 s, that's about two
  # seconds: curl dies on its next write, then the server's next heartbeat fails.
  @heartbeat_ms 1_000

  plug :require_token

  def attach(conn, %{"run" => run} = params) do
    if run == System.get_env("MEERKAT_RUN_ID") or same_review?() do
      stream(conn, run, Map.get(params, "quiet") == "1")
    else
      IO.puts(
        :stderr,
        "meerkat: a later invocation found this review's diff or commit message changed, " <>
          "so it replaces this review — aborting."
      )

      conn = send_resp(conn, 409, "stale\n")
      halt_after_response(1)
      conn
    end
  end

  def attach(conn, _params), do: send_resp(conn, 400, "bad request\n")

  def delivered(conn, %{"run" => run}) do
    case Decision.delivered(run) do
      :ok -> send_resp(conn, 200, "ok\n")
      {:error, :no_outcome} -> send_resp(conn, 409, "no outcome\n")
    end
  end

  def delivered(conn, _params), do: send_resp(conn, 400, "bad request\n")

  defp require_token(conn, _opts) do
    token = System.get_env("MEERKAT_SERVE_TOKEN")

    if is_binary(token) and token != "" and get_req_header(conn, "x-meerkat-token") == [token] do
      conn
    else
      conn |> send_resp(403, "forbidden\n") |> halt()
    end
  end

  defp same_review? do
    base = Application.fetch_env!(:meerkat, :review_state)

    case ReviewState.from_target(
           Application.fetch_env!(:meerkat, :review_target),
           Application.fetch_env!(:meerkat, :repo_path)
         ) do
      {:ok, now} ->
        Persistence.state_signature(now) == Persistence.state_signature(base) and
          now.commit_message == base.commit_message

      {:error, _} ->
        false
    end
  end

  defp stream(conn, run, quiet?) do
    case Decision.attach(run) do
      :closing ->
        send_resp(conn, 503, "closing\n")

      {:ok, nil} ->
        conn = send_chunked(conn, 200)
        # The CLI publishes the outcome 750 ms after a click so the tab can
        # render the done view first. A caller can attach in that window
        # before an outcome is held; Decision.current/0 catches it.
        quiet? = quiet? or Decision.current() != nil
        banner = if quiet?, do: "", else: Application.get_env(:meerkat, :review_banner, "")

        with {:ok, conn} <- chunk(conn, frames(banner)) do
          unless quiet?, do: open_browser_if_unwatched(conn, run)
          await_outcome(conn)
        end

      {:ok, held} ->
        conn |> send_chunked(200) |> send_outcome(held)
    end
  end

  # The CLI opened the tab for the backend's own run at startup.
  defp open_browser_if_unwatched(conn, run) do
    if run != System.get_env("MEERKAT_RUN_ID") and Meerkat.Viewers.count() == 0 and
         not Application.get_env(:meerkat, :no_open, false) do
      open = Application.get_env(:meerkat, :browser_open_fun, &Meerkat.Browser.open/1)
      open.("http://127.0.0.1:#{conn.port}/")
    end
  end

  defp await_outcome(conn) do
    receive do
      {:meerkat_outcome, outcome} ->
        send_outcome(conn, outcome)

      :meerkat_displaced ->
        case chunk(conn, "d\n") do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end
    after
      @heartbeat_ms ->
        case chunk(conn, "k\n") do
          {:ok, conn} -> await_outcome(conn)
          {:error, _} -> conn
        end
    end
  end

  defp send_outcome(conn, {code, text}) do
    case chunk(conn, [frames(text), "x #{code}\n"]) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  @doc false
  def frames(text) do
    {lines, [last]} = text |> String.split("\n") |> Enum.split(-1)
    Enum.map(lines, &["o ", &1, "\n"]) ++ if(last == "", do: [], else: [["n ", last, "\n"]])
  end

  defp halt_after_response(code) do
    halt = Application.get_env(:meerkat, :restart_fun, &System.halt/1)

    Task.start(fn ->
      # Lets the 409 reach the caller first.
      Process.sleep(200)
      halt.(code)
    end)
  end
end
