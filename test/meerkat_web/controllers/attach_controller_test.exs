defmodule MeerkatWeb.AttachControllerTest do
  use MeerkatWeb.ConnCase, async: false

  # Surviving muex mutant in attach_controller.ex, and why it is not a test gap:
  # - await_outcome/1 (delete the `{:error, _} -> conn` clause from
  #   `case chunk(conn, ["d ", text, "\n"])`) handles a displaced caller whose
  #   connection closed before the `d` frame was written. Plug's test adapter
  #   never fails a chunk, so ExUnit cannot reach it.

  import Meerkat.TestHelpers

  alias Meerkat.{Decision, ReviewState}
  alias MeerkatWeb.AttachController

  @token "test-token"
  @own_run "own-run"

  setup do
    isolate_git_config()
    repo = make_git_repo("meerkat-attach")

    git(repo, [
      "-c",
      "user.email=t@t",
      "-c",
      "user.name=t",
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      "init"
    ])

    stage(repo, "a.txt", "one\n")
    msg = Path.join(repo, "MSG")
    File.write!(msg, "first message\n")
    target = {:staged, msg}
    {:ok, state} = ReviewState.from_target(target, repo)

    env = %{"MEERKAT_SERVE_TOKEN" => @token, "MEERKAT_RUN_ID" => @own_run}
    previous_env = Map.new(env, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

    test_pid = self()

    app_env = [
      repo_path: repo,
      review_id: "attach-test",
      review_target: target,
      review_state: state,
      review_banner: "BANNER line\n",
      no_open: true,
      restart_fun: fn code -> send(test_pid, {:halted, code}) end,
      browser_open_fun: fn url -> send(test_pid, {:opened, url}) end
    ]

    previous_app = Map.new(app_env, fn {k, _} -> {k, Application.fetch_env(:meerkat, k)} end)
    Enum.each(app_env, fn {k, v} -> Application.put_env(:meerkat, k, v) end)
    Decision.reset()
    Phoenix.PubSub.subscribe(Meerkat.PubSub, Decision.deadline_topic())

    on_exit(fn ->
      Enum.each(previous_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      Enum.each(previous_app, fn
        {k, {:ok, v}} -> Application.put_env(:meerkat, k, v)
        {k, :error} -> Application.delete_env(:meerkat, k)
      end)

      Application.delete_env(:meerkat, :review_deadline_ms)
      Decision.reset()
      File.rm_rf(repo)
    end)

    %{repo: repo, msg: msg}
  end

  defp attach(conn, run, quiet \\ "0") do
    conn
    |> put_req_header("x-meerkat-token", @token)
    |> get("/api/attach?run=#{run}&quiet=#{quiet}")
  end

  # An attach made before a decision arms the deadline; Decision broadcasts on its
  # deadline topic, which setup subscribes to, so receiving this confirms the caller
  # attached.
  defp await_attached do
    assert_receive {:meerkat_deadline, _}, 5000
  end

  # An attach made after a decision arms no deadline, so poll Decision instead.
  defp await_callers(n, tries \\ 500) do
    cond do
      map_size(:sys.get_state(Decision).callers) == n ->
        :ok

      tries == 0 ->
        flunk("expected #{n} attached caller(s)")

      true ->
        Process.sleep(10)
        await_callers(n, tries - 1)
    end
  end

  defp delivered(conn, run) do
    conn
    |> put_req_header("x-meerkat-token", @token)
    |> post("/api/attach/delivered?run=#{run}")
  end

  test "frames mark each whole line, and a last line without a newline" do
    assert IO.iodata_to_binary(AttachController.frames("a\n\nb\n")) == "o a\no \no b\n"
    assert IO.iodata_to_binary(AttachController.frames("a\ntail")) == "o a\nn tail\n"
    assert IO.iodata_to_binary(AttachController.frames("")) == ""
  end

  test "a request without the backend's token is refused", %{conn: conn} do
    conn = get(conn, "/api/attach?run=#{@own_run}")
    assert conn.status == 403
  end

  test "a backend started without a token refuses a request carrying an empty one",
       %{conn: conn} do
    System.put_env("MEERKAT_SERVE_TOKEN", "")

    conn =
      conn
      |> put_req_header("x-meerkat-token", "")
      |> get("/api/attach?run=#{@own_run}")

    assert conn.status == 403
  end

  test "the caller that started the backend gets the banner, then the outcome and its exit code",
       %{conn: conn} do
    task = Task.async(fn -> attach(conn, @own_run) end)
    await_attached()
    :ok = Decision.publish({1, "feedback\n"})
    conn = Task.await(task)

    assert conn.status == 200
    assert conn.resp_body =~ ~r/\Ao BANNER line\n(k\n)*o feedback\nx 1\n\z/
  end

  test "a later invocation of the same review replays the held outcome byte for byte, without the banner",
       %{conn: conn} do
    :ok = Decision.publish({0, "The user approved your commit. Proceeding.\n"})
    conn = attach(conn, "later-run")

    assert conn.status == 200
    assert conn.resp_body == "o The user approved your commit. Proceeding.\nx 0\n"
    refute_receive {:halted, _}, 300
  end

  test "a later invocation attaching after the click, before the outcome is published, gets no banner and opens no tab",
       %{conn: conn} do
    Application.put_env(:meerkat, :no_open, false)
    {:ok, _} = Decision.submit({:approve, ""})
    task = Task.async(fn -> attach(conn, "later-run") end)
    await_callers(1)

    :ok = Decision.publish({0, "approved\n"})
    assert Task.await(task).resp_body =~ ~r/\A(k\n)*o approved\nx 0\n\z/
    # The task sends {:opened, _} before its reply, so it would already be here.
    refute_received {:opened, _}
  end

  test "a caller is told when a later invocation of the same review takes it over",
       %{conn: conn} do
    first = Task.async(fn -> attach(conn, @own_run) end)
    await_attached()
    second = Task.async(fn -> attach(conn, "later-run") end)
    await_attached()

    displaced = Task.await(first)
    assert displaced.status == 200

    assert displaced.resp_body =~
             ~r/\Ao BANNER line\n(k\n)*d meerkat: a later invocation of this review took it over — aborting\.\n\z/

    :ok = Decision.publish({0, "approved\n"})
    taken_over = Task.await(second)
    assert taken_over.resp_body =~ ~r/\Ao BANNER line\n(k\n)*o approved\nx 0\n\z/
  end

  test "a later invocation whose staged content changed replaces the review",
       %{conn: conn, repo: repo} do
    :ok = Decision.publish({0, "approved\n"})
    stage(repo, "a.txt", "two\n")

    conn = attach(conn, "later-run")

    assert conn.status == 409
    refute conn.resp_body =~ "approved"
    assert_receive {:halted, 1}, 1000
  end

  test "a later invocation whose commit message changed replaces the review",
       %{conn: conn, msg: msg} do
    File.write!(msg, "reworded message\n")

    conn = attach(conn, "later-run")

    assert conn.status == 409
    assert_receive {:halted, 1}, 1000
  end

  test "a caller attached to a review that changed is told so before the backend halts",
       %{conn: conn, repo: repo} do
    first = Task.async(fn -> attach(conn, @own_run) end)
    await_attached()
    stage(repo, "a.txt", "two\n")

    assert attach(conn, "later-run").status == 409

    assert Task.await(first).resp_body =~
             ~r/\Ao BANNER line\n(k\n)*d meerkat: a later invocation found this review's diff or commit message changed, so it replaces this review — aborting\.\n\z/

    assert_receive {:halted, 1}, 1000
  end

  test "a later invocation whose target no longer resolves is refused and leaves the review running",
       %{conn: conn} do
    first = Task.async(fn -> attach(conn, @own_run) end)
    await_attached()
    Application.put_env(:meerkat, :review_target, {:single_ref, "no-such-ref"})

    conn = attach(conn, "later-run")

    assert conn.status == 502
    assert conn.resp_body =~ ~r/\Ao meerkat: error resolving review target: .+\n(o .*\n)*\z/
    refute_receive {:halted, _}, 300
    assert map_size(:sys.get_state(Decision).callers) == 1, "the attached caller stays attached"

    :ok = Decision.publish({0, "approved\n"})
    assert Task.await(first).resp_body =~ ~r/\Ao BANNER line\n(k\n)*o approved\nx 0\n\z/
  end

  test "a run id that is not a launcher run id is refused", %{conn: conn} do
    for run <- ["..", "a%2Fb", "."] do
      assert attach(conn, run).status == 400
      assert delivered(conn, run).status == 400
    end

    refute_receive {:halted, _}, 100
  end

  test "a delivery report hands the CLI the run that took delivery", %{conn: conn} do
    parent = self()
    spawn_link(fn -> send(parent, {:delivered_to, Decision.await_delivery()}) end)
    :ok = Decision.publish({0, "approved\n"})

    conn = delivered(conn, "later-run")

    assert conn.status == 200
    assert_receive {:delivered_to, "later-run"}, 1000
  end

  test "a caller attaching after another took delivery is told the backend is closing",
       %{conn: conn} do
    :ok = Decision.publish({0, "approved\n"})
    assert delivered(conn, "later-run").status == 200

    conn = attach(conn, "third-run")

    assert conn.status == 503
    assert conn.resp_body == "closing\n"
  end

  test "a delivery report before any outcome exists is refused", %{conn: conn} do
    parent = self()
    spawn_link(fn -> send(parent, {:delivered_to, Decision.await_delivery()}) end)

    conn = delivered(conn, "later-run")

    assert conn.status == 409
    refute_receive {:delivered_to, _}, 100
  end

  describe "opening the browser on reattach" do
    setup do
      Application.put_env(:meerkat, :no_open, false)
    end

    # Start an attach task while the review is undecided, wait for it to attach, and
    # return a function that publishes an outcome (ending the stream) and returns the
    # finished conn.
    defp attach_waiting(conn, run, quiet \\ "0") do
      task = Task.async(fn -> attach(conn, run, quiet) end)
      await_attached()

      fn ->
        :ok = Decision.publish({0, "approved\n"})
        Task.await(task)
      end
    end

    test "a later invocation with no tab connected opens the review", %{conn: conn} do
      finish = attach_waiting(conn, "later-run")
      assert_receive {:opened, "http://127.0.0.1:" <> _}
      finish.()
    end

    test "a later invocation collecting a held outcome does not open the review",
         %{conn: conn} do
      :ok = Decision.publish({0, "approved\n"})
      attach(conn, "later-run")
      refute_receive {:opened, _}, 100
    end

    test "the invocation that started the backend does not open it again", %{conn: conn} do
      finish = attach_waiting(conn, @own_run)
      refute_receive {:opened, _}, 100
      finish.()
    end

    test "a later invocation does not open a review a tab is already watching",
         %{conn: conn} do
      test_pid = self()

      viewer =
        spawn_link(fn ->
          {:ok, _} = Meerkat.Viewers.register()
          send(test_pid, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered
      finish = attach_waiting(conn, "later-run")
      refute_receive {:opened, _}, 100
      finish.()
      Process.unlink(viewer)
      Process.exit(viewer, :kill)
    end

    test "a later invocation run with --no-open does not open the review", %{conn: conn} do
      Application.put_env(:meerkat, :no_open, true)
      finish = attach_waiting(conn, "later-run")
      refute_receive {:opened, _}, 100
      finish.()
    end

    test "a quiet reattach, after the caller already printed the banner, does not open it",
         %{conn: conn} do
      finish = attach_waiting(conn, "later-run", "1")
      refute_receive {:opened, _}, 100
      finish.()
    end
  end
end
