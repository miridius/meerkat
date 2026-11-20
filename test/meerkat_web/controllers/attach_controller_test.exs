defmodule MeerkatWeb.AttachControllerTest do
  use MeerkatWeb.ConnCase, async: false

  import Meerkat.TestHelpers

  alias Meerkat.{Decision, PendingAnswers, PendingQuestions, ReviewState}
  alias MeerkatWeb.AttachController
  alias Plug.Adapters.Test.Conn, as: TestAdapter

  defmodule ClosedAdapter do
    @moduledoc false
    # Plug's test adapter, except that every chunk fails as on a closed connection.

    defdelegate send_resp(state, status, headers, body), to: TestAdapter
    defdelegate send_chunked(state, status, headers), to: TestAdapter
    defdelegate read_req_body(state, opts), to: TestAdapter
    defdelegate get_peer_data(state), to: TestAdapter
    defdelegate get_http_protocol(state), to: TestAdapter
    def chunk(_state, _body), do: {:error, :closed}
  end

  @token "test-token"
  @own_run "own-run"

  @review %ReviewState{
    files: [%{file_name: "a.txt", effective_oid: "oid-one"}],
    commit_message: "first message"
  }

  # The staged review a `:git` test reads, built once and copied for each.
  setup_all do
    template =
      fixture_template("meerkat-attach-template", fn repo ->
        git(repo, ["init", "-q"])
        commit(repo, "init")
        stage(repo, "a.txt", "one\n")
        File.write!(Path.join(repo, "MSG"), "first message\n")
      end)

    {:ok, template: template}
  end

  # A test whose code never reads the review is tagged
  # `:no_review` and gets none. A test of how a later invocation reads the
  # review from git is tagged `:git` and gets a real staged review. Any
  # other later invocation reads `current`, which the test can change.
  setup ctx do
    cond do
      ctx[:no_review] -> serve_backend([])
      ctx[:git] -> serve_review(ctx.template)
      true -> serve_review()
    end
  end

  defp serve_review do
    repo = make_state_repo("meerkat-attach")
    {:ok, current} = Agent.start_link(fn -> {:ok, @review} end)

    serve_backend(
      repo_path: repo,
      review_target: {:staged, nil},
      review_state: @review,
      read_review_fun: fn _target, _repo, _index -> Agent.get(current, & &1) end
    )

    %{repo: repo, current: current}
  end

  defp serve_review(template) do
    repo = copy_fixture(template, "meerkat-attach")
    msg = Path.join(repo, "MSG")
    target = {:staged, msg}
    {:ok, state} = ReviewState.from_target(target, repo)
    serve_backend(repo_path: repo, review_target: target, review_state: state)
    %{repo: repo, msg: msg}
  end

  defp serve_backend(review_env) do
    env = %{"MEERKAT_SERVE_TOKEN" => @token, "MEERKAT_RUN_ID" => @own_run}
    previous_env = Map.new(env, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

    test_pid = self()

    app_env =
      review_env ++
        [
          review_id: "attach-test",
          review_banner: "BANNER line\n",
          no_open: true,
          restart_fun: fn code -> send(test_pid, {:halted, code}) end,
          browser_open_fun: fn url -> send(test_pid, {:opened, url}) end
        ]

    previous_app = Map.new(app_env, fn {k, _} -> {k, Application.fetch_env(:meerkat, k)} end)
    Enum.each(app_env, fn {k, v} -> Application.put_env(:meerkat, k, v) end)
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
    end)

    :ok
  end

  defp attach(conn, run, quiet \\ "0") do
    conn
    |> put_req_header("x-meerkat-token", @token)
    |> get("/api/attach?run=#{run}&quiet=#{quiet}")
  end

  defp attach_from_index(conn, run, index) do
    conn
    |> put_req_header("x-meerkat-token", @token)
    |> get("/api/attach?run=#{run}&quiet=0&index=#{URI.encode_www_form(index)}")
  end

  # An attach made before a decision arms the deadline; Decision broadcasts on its
  # deadline topic, which setup subscribes to, so receiving this confirms the caller
  # attached.
  defp await_attached do
    assert_receive {:meerkat_deadline, _}
  end

  # An attach made after a decision arms no deadline, so poll Decision instead.
  defp await_callers(n) do
    assert eventually(fn -> map_size(:sys.get_state(Decision).callers) == n end),
           "expected #{n} attached caller(s)"
  end

  defp change_staged_content(current) do
    Agent.update(current, fn _ ->
      {:ok, %{@review | files: [%{file_name: "a.txt", effective_oid: "oid-two"}]}}
    end)
  end

  defp delivered(conn, run) do
    conn
    |> put_req_header("x-meerkat-token", @token)
    |> post("/api/attach/delivered?run=#{run}")
  end

  defp leave(conn, run) do
    conn
    |> put_req_header("x-meerkat-token", @token)
    |> post("/api/attach/leave?run=#{run}")
  end

  @tag :no_review
  test "frames mark each whole line, and a last line without a newline" do
    assert IO.iodata_to_binary(AttachController.frames("a\n\nb\n")) == "o a\no \no b\n"
    assert IO.iodata_to_binary(AttachController.frames("a\ntail")) == "o a\nn tail\n"
    assert IO.iodata_to_binary(AttachController.frames("")) == ""
  end

  test "reattaching a waiting review cannot bypass another round's questions, even when its review cannot be read",
       %{conn: conn, repo: repo, current: current} do
    Application.put_env(:meerkat, :no_open, false)
    answered = %{location: "global", question: "Already answered?"}
    missing = %{location: "file: a.txt", question: "Still owed?"}
    :ok = PendingQuestions.replace(repo, [answered, missing])
    put_pending_answers(repo, [Map.put(answered, :answer, "Yes.")])
    Agent.update(current, fn _ -> {:error, "index gone"} end)

    refused = attach_from_index(conn, "later-run", "missing-index")
    assert refused.status == 200
    assert refused.resp_body =~ "o meerkat: review refused because these questions are unanswered"
    assert refused.resp_body =~ "Still owed?"
    refute refused.resp_body =~ "Already answered?"
    assert refused.resp_body =~ "meerkat --answers"
    assert String.ends_with?(refused.resp_body, "d meerkat: review refused — commit aborted.\n")
    refute refused.resp_body =~ "x "
    assert Decision.current() == nil
    assert :sys.get_state(Decision).callers == %{}
    refute_received {:opened, _}
    refute_received {:halted, _}

    # A complete set reaches the review comparison, without consuming the answers.
    put_pending_answers(repo, Enum.map([answered, missing], &Map.put(&1, :answer, "Yes.")))

    assert attach_from_index(conn, "answered-run", "missing-index").status == 502
    assert length(PendingAnswers.load(repo).answers) == 2
  end

  test "reattach still delivers the accepted round's held question feedback", %{
    conn: conn,
    repo: repo
  } do
    review = %ReviewState{
      global_comments: [
        %{
          finding_type: :question,
          body: "Why this?",
          correct_instructions: false,
          lint_rule: false
        }
      ]
    }

    {:ok, {:reject, feedback}} = Decision.submit_review(:reject, review, repo)
    :ok = Decision.publish({1, feedback})
    delivered = attach(conn, "later-run")

    assert delivered.resp_body ==
             IO.iodata_to_binary([AttachController.frames(feedback), "x 1\n"])

    assert {:ok, [%{question: "Why this?"}]} = PendingQuestions.unanswered(repo)
    refute_received {:opened, _}
  end

  test "corrupt obligations refuse only the reattaching caller and leave the file intact", %{
    conn: conn,
    repo: repo
  } do
    path = PendingQuestions.path_for(repo)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "broken JSON")
    {:error, reason} = PendingQuestions.unanswered(repo)
    refused = attach(conn, "later-run")
    assert refused.status == 200

    assert refused.resp_body ==
             "o meerkat: couldn't read owed questions: #{reason}\n" <>
               "d meerkat: review refused — commit aborted.\n"

    assert Decision.current() == nil
    assert File.read!(path) == "broken JSON"
    refute_received {:halted, _}

    # Corrupt obligations do not withhold an already decided review's feedback.
    {:ok, _} = Decision.submit({:reject, "Fix it."})
    :ok = Decision.publish({1, "Fix it."})

    assert attach(conn, "decided-run").resp_body ==
             IO.iodata_to_binary([AttachController.frames("Fix it."), "x 1\n"])
  end

  @tag :no_review
  test "an authorized attach with no run or a non-string run is a bad request", %{conn: conn} do
    for path <- ["/api/attach", "/api/attach?run[]=later-run"] do
      refused = conn |> put_req_header("x-meerkat-token", @token) |> get(path)
      assert refused.status == 400
      assert refused.resp_body == "bad request\n"
      assert Decision.current() == nil
      assert :sys.get_state(Decision).callers == %{}
    end
  end

  @tag :no_review
  test "an authorized delivery report with no run or a non-string run is a bad request", %{
    conn: conn
  } do
    :ok = Decision.publish({0, "approved\n"})

    for path <- ["/api/attach/delivered", "/api/attach/delivered?run[]=later-run"] do
      refused = conn |> put_req_header("x-meerkat-token", @token) |> post(path)
      assert {refused.status, refused.resp_body} == {400, "bad request\n"}
    end
  end

  @tag :no_review
  test "a request without the backend's token is refused", %{conn: conn} do
    conn = get(conn, "/api/attach?run=#{@own_run}")
    assert {conn.status, conn.resp_body} == {403, "forbidden\n"}
  end

  @tag :no_review
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

  test "a backend with no banner sends the waiting caller none", %{conn: conn} do
    Application.delete_env(:meerkat, :review_banner)
    task = Task.async(fn -> attach(conn, @own_run) end)
    await_attached()
    :ok = Decision.publish({0, "approved\n"})

    assert Task.await(task).resp_body =~ ~r/\A(k\n)*o approved\nx 0\n\z/
  end

  test "a later invocation of the same review replays the held outcome byte for byte, without the banner",
       %{conn: conn} do
    :ok = Decision.publish({0, "The user approved your commit. Proceeding.\n"})
    conn = attach(conn, "later-run")

    assert conn.status == 200
    assert conn.resp_body == "o The user approved your commit. Proceeding.\nx 0\n"
    refute_receive {:halted, _}, 300
  end

  test "the invocation that started the backend collects the outcome without comparing the review",
       %{conn: conn, current: current} do
    :ok = Decision.publish({0, "approved\n"})
    change_staged_content(current)

    conn = attach(conn, @own_run)

    assert {conn.status, conn.resp_body} == {200, "o approved\nx 0\n"}
    refute_received {:halted, _}
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
       %{conn: conn, current: current} do
    :ok = Decision.publish({0, "approved\n"})
    change_staged_content(current)

    conn = attach(conn, "later-run")

    assert {conn.status, conn.resp_body} == {409, "stale\n"}
    assert_receive {:halted, 1}
  end

  test "a replaced review halts its backend only after the 409 has had time to reach the caller",
       %{conn: conn, current: current} do
    test_pid = self()

    Application.put_env(:meerkat, :restart_fun, fn code ->
      send(test_pid, {:halted, code, System.monotonic_time(:millisecond)})
    end)

    change_staged_content(current)

    assert attach(conn, "later-run").status == 409
    answered_at = System.monotonic_time(:millisecond)

    assert_receive {:halted, 1, halted_at}
    assert halted_at - answered_at >= 100
  end

  # A caller attached for `run` that, once displaced, runs `on_displaced`
  # and then exits.
  defp fake_caller(run, on_displaced) do
    test_pid = self()

    pid =
      spawn(fn ->
        {:ok, _} = Decision.attach(run)
        send(test_pid, {:attached, self()})

        receive do
          {:meerkat_displaced, _} -> on_displaced.()
        end
      end)

    assert_receive {:attached, ^pid}
    pid
  end

  test "a replaced review answers 409 only once its displaced callers have exited",
       %{conn: conn, current: current} do
    slow = fake_caller("waiting-run", fn -> Process.sleep(200) end)
    change_staged_content(current)
    started = System.monotonic_time(:millisecond)

    assert attach(conn, "later-run").status == 409

    refute Process.alive?(slow)
    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "a displaced caller that never exits holds back the 409 for a second at most",
       %{conn: conn, current: current} do
    stuck = for _ <- 1..2, do: fake_caller("waiting-run", fn -> Process.sleep(:infinity) end)
    change_staged_content(current)

    task =
      Task.async(fn ->
        conn = attach(conn, "later-run")
        {:monitors, monitors} = Process.info(self(), :monitors)
        {conn, monitors}
      end)

    # Hold the request past its wait for the first caller, so the second
    # caller's wait starts after the deadline.
    assert eventually(fn ->
             {:monitors, monitors} = Process.info(task.pid, :monitors)

             Enum.all?(stuck, &({:process, &1} in monitors)) and
               Process.info(task.pid, :status) == {:status, :waiting}
           end)

    :erlang.suspend_process(task.pid)
    Process.sleep(1_100)
    :erlang.resume_process(task.pid)

    {conn, monitors} = Task.await(task)
    assert conn.status == 409
    assert Enum.all?(stuck, &({:process, &1} not in monitors))
    Enum.each(stuck, &Process.exit(&1, :kill))
  end

  test "a later invocation whose commit message changed replaces the review",
       %{conn: conn, current: current} do
    Agent.update(current, fn _ -> {:ok, %{@review | commit_message: "reworded message"}} end)

    conn = attach(conn, "later-run")

    assert conn.status == 409
    assert_receive {:halted, 1}
  end

  describe "the index file a staged review reads" do
    # `git commit` hands its hook a relative `.git/index`; `git commit -a` and
    # `git commit <path>` hand it a temporary one holding what they will commit.
    # The backend was started by an invocation git gave this index file.
    @describetag :git

    setup do
      put_env("GIT_INDEX_FILE", ".git/index")
    end

    test "a later invocation given the same index file replays the held outcome",
         %{conn: conn, repo: repo} do
      :ok = Decision.publish({0, "approved\n"})

      for index <- [".git/index", Path.join(repo, ".git/index")] do
        conn = attach_from_index(conn, "later-run", index)

        assert conn.status == 200
        assert conn.resp_body == "o approved\nx 0\n"
      end

      refute_receive {:halted, _}, 300
    end

    test "a later invocation is compared with the index it names, not the copy the backend keeps",
         %{conn: conn, repo: repo} do
      held = Path.join(repo, ".git/held-index")
      File.cp!(Path.join(repo, ".git/index"), held)
      Application.put_env(:meerkat, :held_index, held)
      on_exit(fn -> Application.delete_env(:meerkat, :held_index) end)
      stage(repo, "a.txt", "two\n")

      conn = attach_from_index(conn, "later-run", ".git/index")

      assert conn.status == 409
      assert_receive {:halted, 1}
    end

    test "a later invocation given another index file with the same content replays the held outcome",
         %{conn: conn, repo: repo} do
      :ok = Decision.publish({0, "approved\n"})
      # A retried `git commit <path>` names a new file after its pid.
      retry = temporary_index(repo, "next-index-2.lock", %{"a.txt" => "one\n"})

      conn = attach_from_index(conn, "later-run", retry)

      assert conn.status == 200
      assert conn.resp_body == "o approved\nx 0\n"
      refute_receive {:halted, _}, 300
    end

    test "a later invocation given an index file with other content replaces the review",
         %{conn: conn, repo: repo} do
      :ok = Decision.publish({0, "approved\n"})
      all = temporary_index(repo, "index.lock", %{"a.txt" => "one\n", "b.txt" => "two\n"})

      conn = attach_from_index(conn, "later-run", all)

      assert conn.status == 409
      refute conn.resp_body =~ "approved"
      assert_receive {:halted, 1}
    end

    test "a later invocation given no index file reads the repo's own index",
         %{conn: conn, repo: repo} do
      :ok = Decision.publish({0, "approved\n"})

      assert attach(conn, "later-run").status == 200
      refute_receive {:halted, _}, 300

      stage(repo, "a.txt", "two\n")
      assert attach(conn, "later-run").status == 409
      assert_receive {:halted, 1}
    end

    test "a later invocation whose index file git has removed is refused and keeps the review",
         %{conn: conn, repo: repo} do
      :ok = Decision.publish({0, "approved\n"})

      conn = attach_from_index(conn, "later-run", Path.join(repo, ".git/index.lock"))

      assert conn.status == 502
      assert conn.resp_body =~ "no longer exists"
      refute_receive {:halted, _}, 300
    end

    test "a later invocation of a review that is not staged does not check the index file",
         %{conn: conn, repo: repo} do
      target = {:range, "HEAD", "HEAD", :two_dot}
      {:ok, state} = ReviewState.from_target(target, repo)
      Application.put_env(:meerkat, :review_target, target)
      Application.put_env(:meerkat, :review_state, state)
      :ok = Decision.publish({0, "approved\n"})

      conn = attach_from_index(conn, "later-run", Path.join(repo, ".git/index.lock"))

      assert conn.status == 200
      refute_receive {:halted, _}, 300
    end
  end

  test "a caller attached to a review that changed is told so before the backend halts",
       %{conn: conn, current: current} do
    first = Task.async(fn -> attach(conn, @own_run) end)
    await_attached()
    change_staged_content(current)

    assert attach(conn, "later-run").status == 409

    assert Task.await(first).resp_body =~
             ~r/\Ao BANNER line\n(k\n)*d meerkat: a later invocation found this review's diff or commit message changed, so it replaces this review — aborting\.\n\z/

    assert_receive {:halted, 1}
  end

  test "a later invocation whose target no longer resolves is refused and leaves the review running",
       %{conn: conn, current: current} do
    first = Task.async(fn -> attach(conn, @own_run) end)
    await_attached()
    Agent.update(current, fn _ -> {:error, "unknown revision no-such-ref"} end)

    conn = attach(conn, "later-run")

    assert conn.status == 502

    assert conn.resp_body ==
             "o meerkat: error resolving review target: unknown revision no-such-ref\n"

    refute_receive {:halted, _}, 300
    assert map_size(:sys.get_state(Decision).callers) == 1, "the attached caller stays attached"

    :ok = Decision.publish({0, "approved\n"})
    assert Task.await(first).resp_body =~ ~r/\Ao BANNER line\n(k\n)*o approved\nx 0\n\z/
  end

  @tag :no_review
  test "a run id that is not a launcher run id is refused", %{conn: conn} do
    for run <- ["..", "a%2Fb", "."] do
      refused = attach(conn, run)
      assert {refused.status, refused.resp_body} == {400, "bad request\n"}
      assert delivered(conn, run).status == 400
      assert leave(conn, run).status == 400
    end

    refute_receive {:halted, _}, 100
  end

  describe "a caller leaving before the outcome" do
    test "is told the review ended when it had no comments", %{conn: conn, repo: repo} do
      serve_dir = Path.join(repo, "run")
      File.mkdir_p!(serve_dir)
      Application.put_env(:meerkat, :serve_dir, serve_dir)

      on_exit(fn ->
        Application.delete_env(:meerkat, :serve_dir)

        for {pid, _} <- Registry.lookup(Meerkat.ReviewRegistry, "attach-test"),
            do: DynamicSupervisor.terminate_child(Meerkat.ReviewServerSup, pid)
      end)

      conn = leave(conn, "later-run")

      assert {conn.status, conn.resp_body} == {200, "ended\n"}
      assert Decision.current() == {:ended, ""}
    end

    @tag :no_review
    test "is refused without a single run id", %{conn: conn} do
      for query <- ["", "?run[]=a"] do
        conn =
          conn |> put_req_header("x-meerkat-token", @token) |> post("/api/attach/leave#{query}")

        assert {conn.status, conn.resp_body} == {400, "bad request\n"}
      end
    end

    test "is told the review is still open when nothing judges it", %{conn: conn} do
      conn = leave(conn, "later-run")

      assert {conn.status, conn.resp_body} == {200, "open\n"}
      assert Decision.current() == nil
    end
  end

  test "a request with no run id, or a run that is not a string, is refused", %{conn: conn} do
    conn = put_req_header(conn, "x-meerkat-token", @token)

    for query <- ["", "?run[]=a", "?run[x]=a"] do
      refuted = get(conn, "/api/attach" <> query)
      assert {refuted.status, refuted.resp_body} == {400, "bad request\n"}
    end

    assert map_size(:sys.get_state(Decision).callers) == 0
  end

  test "a caller waiting on the review is sent a heartbeat while nobody decides",
       %{conn: conn} do
    task = Task.async(fn -> attach(conn, @own_run) end)
    await_attached()
    # Longer than one 500 ms heartbeat interval.
    Process.sleep(700)
    :ok = Decision.publish({0, "approved\n"})

    assert Task.await(task).resp_body =~ ~r/\Ao BANNER line\n(k\n)+o approved\nx 0\n\z/
  end

  describe "a caller whose connection has closed" do
    # Plug's test adapter never fails a chunk, so these go over a real socket.
    setup do
      http = Meerkat.CLI.endpoint_config_for_test(0)[:http]
      server = start_supervised!({Bandit, [plug: MeerkatWeb.Endpoint] ++ http})
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      %{port: port}
    end

    # Attaches as `run` over TCP, reads the banner, then hangs up. Zero
    # linger resets the connection, so the server's next write fails.
    defp attach_and_hang_up(port, run) do
      {:ok, socket} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, linger: {true, 0}])

      :ok =
        :gen_tcp.send(
          socket,
          "GET /api/attach?run=#{run}&quiet=0 HTTP/1.1\r\nhost: localhost\r\n" <>
            "x-meerkat-token: #{@token}\r\n\r\n"
        )

      recv_until(socket, "BANNER line", "")
      :ok = :gen_tcp.close(socket)
    end

    defp recv_until(socket, wanted, seen) do
      unless seen =~ wanted do
        {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
        recv_until(socket, wanted, seen <> more)
      end
    end

    test "stops waiting once a heartbeat cannot be sent, without crashing", %{port: port} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          attach_and_hang_up(port, @own_run)
          # Heartbeats go every 500 ms; a write to the closed socket fails
          # within a few, and the handler returns.
          await_callers(0)
          Process.sleep(100)
        end)

      refute log =~ "error"
    end

    test "is displaced quietly, without crashing", %{conn: conn, port: port} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          attach_and_hang_up(port, @own_run)
          await_attached()
          task = Task.async(fn -> attach(conn, "later-run") end)
          await_attached()
          :ok = Decision.publish({0, "approved\n"})
          Task.await(task)
          Process.sleep(100)
        end)

      refute log =~ "error"
    end
  end

  describe "a caller whose connection fails its first write" do
    # Attaches as the backend's own run through `ClosedAdapter`, which fails
    # every chunk the way a closed connection does.
    defp attach_closed(conn) do
      conn = TestAdapter.conn(conn, :get, "/api/attach?run=#{@own_run}&quiet=0", nil)
      {TestAdapter, state} = conn.adapter

      %{conn | adapter: {ClosedAdapter, state}}
      |> put_req_header("x-meerkat-token", @token)
      |> MeerkatWeb.Endpoint.call([])
    end

    test "gives up on the banner without crashing", %{conn: conn} do
      assert attach_closed(conn).state == :chunked
    end

    test "gives up on a held outcome without crashing", %{conn: conn} do
      :ok = Decision.publish({0, "approved\n"})
      assert attach_closed(conn).state == :chunked
    end
  end

  test "a delivery report hands the CLI the run that took delivery", %{conn: conn} do
    parent = self()
    spawn_link(fn -> send(parent, {:delivered_to, Decision.await_delivery()}) end)
    :ok = Decision.publish({0, "approved\n"})

    conn = delivered(conn, "later-run")

    assert {conn.status, conn.resp_body} == {200, "ok\n"}
    assert_receive {:delivered_to, "later-run"}
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

    assert {conn.status, conn.resp_body} == {409, "no outcome\n"}
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
      assert_receive {:opened, "http://127.0.0.1:80/"}
      finish.()
    end

    test "a backend not told --no-open opens the review", %{conn: conn} do
      Application.delete_env(:meerkat, :no_open)
      finish = attach_waiting(conn, "later-run")
      assert_receive {:opened, _}
      finish.()
    end

    test "with no opener configured, the OS open command opens the review", %{conn: conn} do
      bin = tmp_path("meerkat-attach-open")
      File.mkdir_p!(bin)
      on_exit(fn -> File.rm_rf!(bin) end)
      log = Path.join(bin, "args")
      {cmd, _args} = Meerkat.Browser.open_argv_for(:os.type(), "")
      File.write!(Path.join(bin, cmd), "#!/bin/sh\nprintf '%s\\n' \"$@\" > '#{log}'\n")
      File.chmod!(Path.join(bin, cmd), 0o755)
      put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
      Application.delete_env(:meerkat, :browser_open_fun)

      attach_waiting(conn, "later-run").()

      assert File.read!(log) == "http://127.0.0.1:80/\n"
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
      assert finish.().resp_body =~ ~r/\A(k\n)*o approved\nx 0\n\z/
    end
  end
end
