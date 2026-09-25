defmodule MeerkatWeb.AttachControllerTest do
  use MeerkatWeb.ConnCase, async: false

  # Surviving muex mutant in attach_controller.ex, and why it is not a
  # test gap:
  #
  # - attach_controller.ex:120 send_outcome (delete the `{:error, _}`
  #   clause) — the clause handles a caller whose connection closed
  #   before the outcome was written. Plug's test adapter never fails a
  #   chunk, so ExUnit cannot reach it.

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

  test "the caller that started the backend gets the banner, then the held outcome and its exit code",
       %{conn: conn} do
    :ok = Decision.publish({1, "feedback\n"})
    conn = attach(conn, @own_run)

    assert conn.status == 200
    assert conn.resp_body == "o BANNER line\no feedback\nx 1\n"
  end

  test "a later invocation of the same review replays the held outcome byte for byte",
       %{conn: conn} do
    :ok = Decision.publish({0, "The user approved your commit. Proceeding.\n"})
    conn = attach(conn, "later-run")

    assert conn.status == 200

    assert conn.resp_body ==
             "o BANNER line\no The user approved your commit. Proceeding.\nx 0\n"

    refute_receive {:halted, _}, 300
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

  test "a later invocation whose target no longer resolves replaces the review",
       %{conn: conn} do
    Application.put_env(:meerkat, :review_target, {:single_ref, "no-such-ref"})

    conn = attach(conn, "later-run")

    assert conn.status == 409
    assert_receive {:halted, 1}, 1000
  end

  test "a delivery report hands the CLI the run that took delivery", %{conn: conn} do
    parent = self()
    spawn_link(fn -> send(parent, {:delivered_to, Decision.await_delivery()}) end)
    :ok = Decision.publish({0, "approved\n"})

    conn = delivered(conn, "later-run")

    assert conn.status == 200
    assert_receive {:delivered_to, "later-run"}, 1000
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
      :ok = Decision.publish({0, "approved\n"})
    end

    test "a later invocation with no tab connected opens the review", %{conn: conn} do
      attach(conn, "later-run")
      assert_receive {:opened, "http://127.0.0.1:" <> _}
    end

    test "the invocation that started the backend does not open it again", %{conn: conn} do
      attach(conn, @own_run)
      refute_receive {:opened, _}, 100
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
      attach(conn, "later-run")
      refute_receive {:opened, _}, 100
      Process.unlink(viewer)
      Process.exit(viewer, :kill)
    end

    test "a later invocation run with --no-open does not open the review", %{conn: conn} do
      Application.put_env(:meerkat, :no_open, true)
      attach(conn, "later-run")
      refute_receive {:opened, _}, 100
    end

    test "a quiet reattach, after the caller already printed the banner, does not open it",
         %{conn: conn} do
      attach(conn, "later-run", "1")
      refute_receive {:opened, _}, 100
    end
  end
end
