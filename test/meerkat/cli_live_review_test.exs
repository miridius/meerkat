defmodule Meerkat.CLILiveReviewTest do
  # A live review run in this BEAM, which stops where announcing it needs a
  # bound port, and the steps a review takes once it is decided. Not async:
  # these change the application env, the logger's handlers, the OS
  # environment and `Meerkat.Decision`.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers

  alias Meerkat.{ApprovalCache, CLI, Decision, Git, Persistence, ReviewId, ReviewLog, ReviewState}
  alias Meerkat.Timeout

  setup do
    repo = make_git_repo("meerkat-cli-live")
    on_exit(fn -> File.rm_rf!(repo) end)
    commit(repo, "seed")

    for name <-
          ~w(MEERKAT_SERVE_DIR MEERKAT_RUN_ID MEERKAT_PREFERRED_PORT MEERKAT_REVIEW_TIMEOUT MEERKAT_AUTO_APPROVE_ON_TIMEOUT),
        do: put_env(name, nil)

    put_env("MEERKAT_PWD", repo)
    restore_app_env_on_exit()
    root = CLI.repo_path_for_test()
    {:ok, root: root, meerkat_dir: Git.meerkat_dir(root)}
  end

  # Puts back every `:meerkat` application env key as it was.
  defp restore_app_env_on_exit do
    before = Application.get_all_env(:meerkat)

    on_exit(fn ->
      for {key, _} <- Application.get_all_env(:meerkat),
          not Keyword.has_key?(before, key),
          do: Application.delete_env(:meerkat, key)

      for {key, value} <- before, do: Application.put_env(:meerkat, key, value)
    end)
  end

  defp with_stderr(fun), do: ExUnit.CaptureIO.with_io(:stderr, fun)

  describe "a live review in a BEAM whose endpoint serves nothing" do
    setup %{root: root} do
      stage(root, "a.txt", "a\n")
      {:ok, default} = :logger.get_handler_config(:default)

      on_exit(fn ->
        _ = :logger.remove_handler(:meerkat_file)

        if match?({:error, _}, :logger.get_handler_config(:default)),
          do: :ok = :logger.add_handler(:default, default.module, default)
      end)

      {:ok,
       approval_cache_path: ApprovalCache.path_for(root),
       review_id: ReviewId.derive(root, {:staged, nil})}
    end

    test "sets the review up and routes its logs to a file, then rejects for want of a bound port",
         ctx do
      stale = Path.join([ctx.meerkat_dir, "deadlines", "stale-run"])
      File.mkdir_p!(stale)
      File.touch!(stale, System.os_time(:second) - div(Timeout.limit_ms(), 1000) - 3600)
      put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", "sometimes")
      # The test VM's own setup sets it.
      Application.delete_env(:meerkat, :start_endpoint)

      {code, stderr} = with_stderr(fn -> CLI.main(["--no-open", "--port", "4321"]) end)

      assert code == 2
      assert stderr =~ ~s(meerkat: ignoring MEERKAT_AUTO_APPROVE_ON_TIMEOUT="sometimes")

      assert stderr =~
               "\nmeerkat: live-review crashed — defaulting to REJECT (commit aborted).\n" <>
                 "** (RuntimeError) could not read the review server's bound port"

      assert Application.get_env(:meerkat, :review_target) == {:staged, nil}
      assert Application.get_env(:meerkat, :no_open) == true
      assert Application.get_env(:meerkat, :review_id) == ctx.review_id
      assert Application.get_env(:meerkat, :repo_path) == ctx.root

      assert %ReviewState{files: [%{file_name: "a.txt"}]} =
               Application.get_env(:meerkat, :review_state)

      assert Application.get_env(:meerkat, :start_endpoint) == true
      assert Application.get_env(:meerkat, :meerkat_dir) == ctx.meerkat_dir
      assert Application.get_env(:meerkat, :approval_cache_path) == ctx.approval_cache_path
      assert Application.get_env(:meerkat, MeerkatWeb.Endpoint)[:http][:port] == 4321

      # Unserved, the review runs out of time on its own clock, and starting
      # it pruned another run's abandoned one.
      assert File.exists?(Path.join([ctx.meerkat_dir, "deadlines", "unkeyed", ctx.review_id]))

      assert Application.get_env(:meerkat, :review_deadline_ms) ==
               Timeout.deadline_ms(ctx.root, ctx.review_id)

      refute File.exists?(stale)

      log_path = Path.join(ctx.meerkat_dir, "meerkat.log")
      assert Application.get_env(:meerkat, :log_path) == log_path
      assert {:ok, %{config: %{file: file}}} = :logger.get_handler_config(:meerkat_file)
      assert List.to_string(file) == log_path
      assert File.exists?(log_path)
      assert {:error, _} = :logger.get_handler_config(:default)

      assert [review_log] =
               Path.wildcard(Path.join([ctx.meerkat_dir, "reviews", "*-files1.json"]))

      assert %{"decision" => "in-progress"} = review_log |> File.read!() |> Jason.decode!()
    end

    test "a served review keeps no clock of its own and binds its preferred port", ctx do
      serve_dir = Path.join(ctx.root, ".git/run")
      File.mkdir_p!(serve_dir)
      put_env("MEERKAT_SERVE_DIR", serve_dir)
      put_env("MEERKAT_PREFERRED_PORT", "4799")

      {code, stderr} = with_stderr(fn -> CLI.main(["--no-open"]) end)

      assert code == 2
      assert stderr =~ "could not read the review server's bound port"
      assert Application.fetch_env(:meerkat, :review_deadline_ms) == {:ok, nil}
      assert Application.get_env(:meerkat, :serve_dir) == serve_dir
      assert Application.get_env(:meerkat, MeerkatWeb.Endpoint)[:http][:port] == 4799
      refute File.exists?(Path.join([ctx.meerkat_dir, "deadlines", "unkeyed", ctx.review_id]))
    end
  end

  describe "concluding a decided review" do
    setup %{root: root, meerkat_dir: meerkat_dir} do
      review_id = "cli-conclude-#{System.unique_integer([:positive])}"
      :ok = Persistence.save(root, review_id, %ReviewState{})
      _ = Timeout.deadline_ms(root, review_id)
      _ = Timeout.deadline_ms(root, review_id, "run-1")

      anchor = fn run -> Path.join([meerkat_dir, "deadlines", run, review_id]) end

      {:ok,
       review_id: review_id,
       log: ReviewLog.start(root, %ReviewState{}),
       snapshot: Persistence.path_for(root, review_id),
       anchor: anchor}
    end

    defp conclude(ctx, decision, serve_dir) do
      test = self()

      with_stderr(fn ->
        CLI.conclude_review_for_test(decision, serve_dir, ctx.review_id, ctx.log, fn ms ->
          send(test, {:paused, ms})
        end)
      end)
    end

    defp logged(ctx), do: ctx.log.path |> File.read!() |> Jason.decode!()

    test "an unserved review prints its outcome, logs it, and clears its snapshot and own clock",
         ctx do
      {code, stderr} = conclude(ctx, {:reject, "PAYLOAD-BODY"}, nil)

      assert code == 1
      feedback = Path.rootname(ctx.log.path) <> ".txt"
      assert stderr =~ "User rejected the commit — full feedback saved to #{feedback}"
      assert File.read!(feedback) == "PAYLOAD-BODY"
      assert_received {:paused, 750}
      assert %{"decision" => "reject", "rendered_feedback" => "PAYLOAD-BODY"} = logged(ctx)
      refute File.exists?(ctx.snapshot)
      refute File.exists?(ctx.anchor.("unkeyed"))
      assert File.exists?(ctx.anchor.("run-1"))
    end

    test "approval with comments is logged as an approval", ctx do
      assert {0, _} = conclude(ctx, {:approve_with_feedback, "PAYLOAD-BODY"}, nil)
      assert %{"decision" => "approve"} = logged(ctx)
    end

    test "an ended review keeps its snapshot and prints its outcome, though served", ctx do
      assert conclude(ctx, {:ended, ""}, "/serve/dir") == {1, "meerkat: the review ended.\n"}
      assert %{"decision" => "ended", "rendered_feedback" => nil} = logged(ctx)
      assert File.exists?(ctx.snapshot)
      refute File.exists?(ctx.anchor.("unkeyed"))
    end

    test "a served review hands its outcome to the attached caller and clears that run's clock",
         ctx do
      {:ok, _} = Decision.submit({:approve, ""})
      test = self()

      spawn_link(fn ->
        {:ok, nil} = Decision.attach("run-1")
        send(test, :attached)

        receive do
          {:meerkat_outcome, outcome} ->
            send(test, {:outcome, outcome})
            :ok = Decision.delivered("run-1")
        end
      end)

      assert_receive :attached
      assert conclude(ctx, {:approve, ""}, "/serve/dir") == {0, ""}
      assert_received {:outcome, {0, "The user approved your commit. Proceeding.\n"}}
      refute File.exists?(ctx.snapshot)
      refute File.exists?(ctx.anchor.("run-1"))
      assert File.exists?(ctx.anchor.("unkeyed"))
    end
  end

  describe "announcing the review" do
    setup do
      Application.put_env(:meerkat, :log_path, "/logs/meerkat.log")
      :ok
    end

    @url "http://127.0.0.1:4799/"

    defp served_on(port), do: fn :http -> {:ok, {{127, 0, 0, 1}, port}} end

    test "an unserved review prints the banner, then where its debug logs are" do
      {:ok, stderr} =
        with_stderr(fn -> CLI.announce_url_for_test({:pr, "1"}, nil, @url, served_on(4799)) end)

      assert String.starts_with?(stderr, "⏸ Paused for human review at #{@url} — may take")
      assert stderr =~ "this `meerkat` process blocks"
      assert String.ends_with?(stderr, "\ndebug logs at: /logs/meerkat.log\n")
      assert Application.get_env(:meerkat, :review_banner) == nil
    end

    test "a served review hands the banner to its caller and records where it serves", ctx do
      serve_dir = Path.join(ctx.root, ".git/serve")
      File.mkdir_p!(serve_dir)

      {:ok, ""} =
        with_stderr(fn ->
          CLI.announce_url_for_test({:staged, "x"}, serve_dir, @url, served_on(4799))
        end)

      banner = Application.get_env(:meerkat, :review_banner)
      assert String.starts_with?(banner, "⏸ Paused for human review at #{@url}")
      assert banner =~ "this `git commit` process blocks"
      assert String.ends_with?(banner, "\ndebug logs at: /logs/meerkat.log\n")
      assert File.exists?(Path.join(serve_dir, "served"))
      assert File.read!(Path.join(serve_dir, "port")) == "4799 #{System.pid()}\n"
    end
  end

  describe "awaiting the decision" do
    test "returns the decision submitted" do
      {:ok, _} = Decision.submit({:reject, "PAYLOAD-BODY"})
      assert CLI.await_decision_or_reject_for_test() == {:reject, "PAYLOAD-BODY"}
    end

    test "with no Decision server, rejects and says so" do
      :ok = Supervisor.terminate_child(Meerkat.Supervisor, Decision)
      on_exit(fn -> {:ok, _} = Supervisor.restart_child(Meerkat.Supervisor, Decision) end)

      assert with_stderr(&CLI.await_decision_or_reject_for_test/0) ==
               {{:cancel, ""},
                "meerkat: Decision GenServer not running — defaulting to REJECT (commit aborted).\n"}
    end
  end

  describe "endpoint_config/1" do
    setup do
      base = Application.get_env(:meerkat, MeerkatWeb.Endpoint)

      dev =
        Keyword.merge(base,
          code_reloader: true,
          debug_errors: true,
          watchers: [vite: []],
          static_url: [host: "dev.test"]
        )

      Application.put_env(:meerkat, MeerkatWeb.Endpoint, dev)
      :ok
    end

    test "a dev build keeps its own endpoint settings" do
      Application.put_env(:meerkat, :dev_endpoint, true)
      config = CLI.endpoint_config_for_test(4321)

      assert config[:code_reloader] == true
      assert config[:debug_errors] == true
      assert config[:watchers] == [vite: []]
      assert config[:static_url] == [host: "dev.test"]
      assert config[:server] == true
      assert config[:http][:port] == 4321
    end

    test "any other build forces them off" do
      for dev_endpoint <- [false, nil] do
        if dev_endpoint == nil,
          do: Application.delete_env(:meerkat, :dev_endpoint),
          else: Application.put_env(:meerkat, :dev_endpoint, dev_endpoint)

        config = CLI.endpoint_config_for_test(4321)

        assert config[:code_reloader] == false
        assert config[:debug_errors] == false
        assert config[:watchers] == []
        assert config[:static_url] == nil
        assert config[:server] == true
      end
    end

    test "with no endpoint configured, serves on the CLI's settings alone" do
      Application.delete_env(:meerkat, MeerkatWeb.Endpoint)
      config = CLI.endpoint_config_for_test(4321)

      assert config[:server] == true
      assert config[:http][:port] == 4321
      assert config[:code_reloader] == false
    end
  end
end
