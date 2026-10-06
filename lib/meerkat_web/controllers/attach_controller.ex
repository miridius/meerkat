defmodule MeerkatWeb.AttachController do
  @moduledoc """
  Endpoints for the caller in `bin/meerkat-attach`. Both require the
  backend's serve token and return 400 when the run id contains anything
  other than letters, digits, and hyphens.

  `GET /api/attach?run=<run>` attaches the caller for its run and
  streams newline-terminated frames: `o <line>` is a line for stderr,
  `n <text>` is stderr text with no trailing newline, `k` is a
  heartbeat, and `x <code>` carries the exit code, last. A later
  invocation whose review changed gets 409, and this BEAM halts so it
  can start a fresh one. A staged review is compared by what the index
  named in the caller's `index=<GIT_INDEX_FILE>` holds, not by that
  file's name (a relative name is taken from the top of the work tree);
  a caller sending none is read from the repo's own index. Before the
  409 is sent, every attached caller
  gets a `d <line>` frame; a displaced caller prints `<line>` to stderr
  and exits 1. Once a caller has taken delivery, others get 503. `quiet=1`
  skips the banner, for a caller that already printed it. A later
  invocation whose review target cannot be resolved, or whose staged
  review names an index that no longer exists, gets 502 with the error
  in `o` frames, and the review keeps running. A caller attaching
  after a decision has been made, whether the outcome is held or a click
  has happened but the outcome has not yet been published, gets no banner
  and opens no browser tab.

  `POST /api/attach/delivered?run=<run>` reports that the caller printed
  the outcome.
  """

  use Phoenix.Controller, formats: []

  import Plug.Conn

  alias Meerkat.{Decision, Git, Persistence, ReviewState}

  # The deadline runs only while a caller is attached. A dead caller is detached when a
  # heartbeat write fails. The write that kills curl and the server's first write after
  # curl dies can both succeed; the next write fails. Detachment can take up to three
  # intervals after the caller dies (1.5 s at 500 ms).
  @heartbeat_ms 500

  plug :require_token
  plug :require_run

  @replaced "meerkat: a later invocation found this review's diff or commit message changed, " <>
              "so it replaces this review — aborting."

  def attach(conn, %{"run" => run} = params) when is_binary(run) do
    compared =
      if run == System.get_env("MEERKAT_RUN_ID"),
        do: :same,
        else: compare_review(Map.get(params, "index", ""))

    case compared do
      :same ->
        stream(conn, run, Map.get(params, "quiet") == "1")

      :changed ->
        # Displace and wait before answering 409: otherwise a caller seeing its
        # connection drop could reattach to the replacement backend and take
        # over its review.
        await_exits(Decision.replace(@replaced))
        conn = send_resp(conn, 409, "stale\n")
        halt_after_response(1)
        conn

      {:error, reason} ->
        body = frames("meerkat: error resolving review target: #{reason}\n")
        send_resp(conn, 502, body)
    end
  end

  def attach(conn, _params), do: send_resp(conn, 400, "bad request\n")

  def delivered(conn, %{"run" => run}) when is_binary(run) do
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

  defp require_run(conn, _opts) do
    case conn.params do
      %{"run" => run} when is_binary(run) ->
        # Run ids name directories under deadlines, so reject paths like "..";
        # launcher ids are UUIDs from uuidgen.
        if run =~ ~r/\A[A-Za-z0-9-]+\z/,
          do: conn,
          else: conn |> send_resp(400, "bad request\n") |> halt()

      _ ->
        conn
    end
  end

  defp compare_review(caller_index) do
    target = Application.fetch_env!(:meerkat, :review_target)
    repo_path = Application.fetch_env!(:meerkat, :repo_path)
    base = Application.fetch_env!(:meerkat, :review_state)

    # A staged review reads the index git handed the caller's hook, which holds
    # different content for `git commit`, `git commit -a` and `git commit <path>`.
    # Its file name says nothing: a path commit's is named after git's pid. The
    # backend's held copy is the first invocation's index, not this caller's.
    # Other targets do not read the index, so its name is not checked.
    caller_index = if match?({:staged, _}, target), do: caller_index

    case Git.with_index(repo_path, caller_index, fn ->
           ReviewState.from_target(target, repo_path)
         end) do
      {:ok, now} ->
        if Persistence.state_signature(now) == Persistence.state_signature(base) and
             now.commit_message == base.commit_message,
           do: :same,
           else: :changed

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_exits(pids) do
    refs = Enum.map(pids, &Process.monitor/1)
    deadline = System.monotonic_time(:millisecond) + 1_000

    Enum.each(refs, fn ref ->
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> Process.demonitor(ref, [:flush])
      end
    end)
  end

  defp stream(conn, run, quiet?) do
    case Decision.attach(run) do
      :closing ->
        send_resp(conn, 503, "closing\n")

      {:ok, nil} ->
        stream_pending(conn, run, quiet?)

      {:ok, held} ->
        conn |> send_chunked(200) |> send_outcome(held)
    end
  end

  defp stream_pending(conn, run, quiet?) do
    conn = send_chunked(conn, 200)
    # The CLI publishes the outcome 750 ms after a click so the tab can
    # render the done view first. A caller can attach in that window
    # before an outcome is held; Decision.current/0 catches it.
    quiet? = quiet? or Decision.current() != nil
    banner = if quiet?, do: "", else: Application.get_env(:meerkat, :review_banner, "")

    case chunk(conn, frames(banner)) do
      {:ok, conn} ->
        unless quiet?, do: open_browser_if_unwatched(conn, run)
        await_outcome(conn)

      {:error, _} ->
        conn
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

      {:meerkat_displaced, text} ->
        case chunk(conn, ["d ", text, "\n"]) do
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
