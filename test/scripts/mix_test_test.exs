defmodule Meerkat.MixTestScriptTest do
  # Runs the repo's real scripts/mix-test.sh, with the scripts it runs, in a
  # temporary git repo against a fixture tree of empty test files; only mix
  # and getconf are PATH stubs. The mix stub logs each run, records each
  # test-file run's start and end, sleeps for a test-set delay, spends two
  # seconds of CPU time more for files named as slow, or named as slow beside
  # others on their first run only, sleeps three seconds more for files named
  # as waiting, prints the file to stdout and stderr, and can fail compile or
  # files named by a test, or kill their jobs. The getconf stub reports a
  # test-set core count. The per-file limits are 10 s of CPU time and 60 s of
  # wall time, so only the over-limit tests, which set them to one and two
  # seconds, can hit them.
  use ExUnit.Case, async: true

  @root File.cwd!()

  @files ~w(test/a_test.exs test/web/b_test.exs test/c_test.exs)

  # A loaded machine can take the over-limit tests' 2 s of wall time on any
  # file, so those tests judge only test/web/b_test.exs.
  @others_exempt Map.new(
                   ~w(test/a_test.exs test/c_test.exs),
                   &{&1, %{reason: "only b_test.exs is judged"}}
                 )

  @over_limits %{limit_seconds: 2, cpu_limit_seconds: 1, exempt: @others_exempt}

  # Spends two seconds of CPU time.
  @spend_cpu ~S"bun -e 'const cpu = ({ user, system } = process.cpuUsage()) => user + system; while (cpu() < 2e6) for (let i = 0; i < 1e6; i++);'"

  setup do
    base = Meerkat.TestHelpers.make_git_repo("meerkat-mix-test")
    on_exit(fn -> File.rm_rf!(base) end)

    stubs = Path.join(base, "stubs")
    log = Path.join(base, "log")
    erl_opts = Path.join(base, "erl_opts")
    build_lock = Path.join(base, "build_lock")
    slot_fd = Path.join(base, "slot_fd")
    spans = Path.join(base, "spans")
    failing = Path.join(base, "failing")
    failing_alone = Path.join(base, "failing_alone")
    killed = Path.join(base, "killed")
    cores = Path.join(base, "cores")
    delay = Path.join(base, "delay")
    slow = Path.join(base, "slow")
    slow_beside = Path.join(base, "slow_beside")
    waiting = Path.join(base, "waiting")
    seen = Path.join(base, "seen")

    File.mkdir_p!(Path.join(base, "scripts"))

    for script <- ~w(mix-test.sh run-test-file.sh gate-lock.sh test-file-times.ts) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([base, "scripts", script]))
    end

    write_limits(base, %{limit_seconds: 60, cpu_limit_seconds: 10, exempt: %{}})

    for file <- @files, do: write_test_file(base, file)

    File.write!(Path.join(base, "test/test_helper.exs"), "")

    for file <- [failing, failing_alone, killed, slow, slow_beside, waiting, seen, slot_fd],
        do: File.write!(file, "")

    File.write!(cores, "4\n")
    File.write!(delay, "0\n")

    File.mkdir_p!(stubs)

    # A file's second run is the one test-file-times.ts starts; the job a stub
    # kills is run-test-file.sh's parent.
    File.write!(Path.join(stubs, "mix"), """
    #!/usr/bin/env bash
    echo "$MIX_ENV mix $*" >> '#{log}'
    echo "$1: ${ELIXIR_ERL_OPTIONS-unset}" >> '#{erl_opts}'
    echo "$1: ${MIX_OS_CONCURRENCY_LOCK-unset}" >> '#{build_lock}'
    if [ "$1" = compile ]; then ! grep -qxF compile '#{failing}'; exit; fi
    if [ -e /dev/fd/9 ]; then echo "$3" >> '#{slot_fd}'; fi
    if grep -qxF "$3" '#{killed}'; then kill -9 $(ps -o ppid= -p "$PPID"); exit 1; fi
    alone=false
    if grep -qxF "$3" '#{seen}'; then alone=true; else echo "$3" >> '#{seen}'; fi
    echo "start" >> '#{spans}'
    sleep "$(cat '#{delay}')"
    if grep -qxF "$3" '#{slow}'; then #{@spend_cpu}; fi
    if [ $alone = false ] && grep -qxF "$3" '#{slow_beside}'; then #{@spend_cpu}; fi
    if grep -qxF "$3" '#{waiting}'; then sleep 3; fi
    echo "end" >> '#{spans}'
    echo "ran $3"
    echo "err $3" >&2
    if [ $alone = true ] && grep -qxF "$3" '#{failing_alone}'; then exit 1; fi
    ! grep -qxF "$3" '#{failing}'
    """)

    File.write!(Path.join(stubs, "getconf"), "#!/usr/bin/env bash\ncat '#{cores}'\n")

    for stub <- ~w(mix getconf), do: File.chmod!(Path.join(stubs, stub), 0o755)

    {:ok,
     base: base,
     stubs: stubs,
     log: log,
     erl_opts: erl_opts,
     build_lock: build_lock,
     slot_fd: slot_fd,
     spans: spans,
     failing: failing,
     failing_alone: failing_alone,
     killed: killed,
     cores: cores,
     delay: delay,
     slow: slow,
     slow_beside: slow_beside,
     waiting: waiting}
  end

  test "compiles once, then runs every test file in its own mix test", ctx do
    assert {out, 0} = run(ctx)
    assert out =~ "all 3 test files passed"

    [compile | tests] = runs(ctx)
    assert compile == "test mix compile"
    assert Enum.sort(tests) == Enum.sort(for f <- @files, do: "test mix test --no-compile #{f}")
  end

  test "test files run on four schedulers that do not busy-wait; the compile does not", ctx do
    assert {_, 0} = run(ctx)

    assert erl_opts(ctx) ==
             ["compile: unset" | List.duplicate("test: +S 4 +sbwt none ", length(@files))]
  end

  test "test files skip mix's build lock; the compile takes it", ctx do
    assert {_, 0} = run(ctx)

    assert lines(ctx.build_lock) == ["compile: unset" | List.duplicate("test: 0", length(@files))]
  end

  test "ELIXIR_ERL_OPTIONS already set follows the test files' flags", ctx do
    assert {_, 0} = run(ctx, [{"ELIXIR_ERL_OPTIONS", "+S 2"}])

    assert erl_opts(ctx) ==
             ["compile: +S 2" | List.duplicate("test: +S 4 +sbwt none +S 2", length(@files))]
  end

  test "a failing compile fails the run before any test file runs", ctx do
    File.write!(ctx.failing, "compile\n")

    assert {_out, status} = run(ctx)
    assert status != 0
    assert runs(ctx) == ["test mix compile"]
  end

  test "a failing file fails the run and has its output shown", ctx do
    File.write!(ctx.failing, "test/web/b_test.exs\n")

    assert {out, 1} = run(ctx)

    assert out =~
             "=== mix test test/web/b_test.exs ===\nran test/web/b_test.exs\nerr test/web/b_test.exs"

    refute out =~ "ran test/a_test.exs"
    assert out =~ "1 of 3 test files failed:\n  test/web/b_test.exs"
    assert length(runs(ctx)) == 4
  end

  test "every failing file is listed", ctx do
    File.write!(ctx.failing, "test/a_test.exs\ntest/c_test.exs\n")

    assert {out, 1} = run(ctx)
    assert out =~ "2 of 3 test files failed:"
    assert out =~ "  test/a_test.exs"
    assert out =~ "  test/c_test.exs"
  end

  test "a file whose job is killed fails the run", ctx do
    File.write!(ctx.killed, "test/web/b_test.exs\n")

    assert {out, 1} = run(ctx)
    assert out =~ "=== mix test test/web/b_test.exs did not finish ==="
    assert out =~ "test files failed:"
  end

  test "a failing file fails the run even beside a file whose path differs only in slashes",
       ctx do
    write_test_file(ctx.base, "test/x/y_z_test.exs")
    write_test_file(ctx.base, "test/x_y/z_test.exs")
    File.write!(ctx.failing, "test/x/y_z_test.exs\n")

    assert {out, 1} = run(ctx)
    assert out =~ "1 of 5 test files failed:\n  test/x/y_z_test.exs"
  end

  test "runs half the cores' worth of files at once", ctx do
    File.write!(ctx.cores, "4\n")
    File.write!(ctx.delay, "0.5\n")
    assert {_, 0} = run(ctx)
    assert most_at_once(ctx) == 2
  end

  test "runs one file at a time on a single core", ctx do
    File.write!(ctx.cores, "1\n")
    File.write!(ctx.delay, "0.5\n")
    assert {_, 0} = run(ctx)
    assert most_at_once(ctx) == 1
  end

  test "two runs at once share half the cores' worth of slots", ctx do
    File.write!(ctx.cores, "4\n")
    File.write!(ctx.delay, "0.5\n")

    runs = for _ <- 1..2, do: Task.async(fn -> run(ctx) end)

    for {out, status} <- Task.await_many(runs, :infinity), do: assert(status == 0, out)

    assert most_at_once(ctx) == 2
  end

  describe "the per-file time limit" do
    test "a file still over the limit when run again fails the run and is named", ctx do
      File.write!(ctx.slow, "test/web/b_test.exs\n")
      write_limits(ctx.base, @over_limits)

      assert {out, 1} = run(ctx)

      assert out =~ ~r/  test\/web\/b_test.exs: \d+\.\d s beside others, \d+\.\d s run again\n/

      assert out =~
               ~r/test files over the 1 s CPU-time limit for one file, run again:\n  test\/web\/b_test.exs: \d+\.\d s\n/

      refute out =~ "all 3 test files passed"
    end

    test "time a file spends waiting does not count", ctx do
      File.write!(ctx.waiting, "test/web/b_test.exs\n")
      write_limits(ctx.base, @over_limits)

      assert {out, 0} = run(ctx)
      refute out =~ "running again"
    end

    test "in CI, time a file spends waiting counts", ctx do
      File.write!(ctx.waiting, "test/web/b_test.exs\n")
      write_limits(ctx.base, @over_limits)

      assert {out, 1} = run(ctx, [{"CI", "true"}])

      assert out =~
               ~r/test files over the 2 s wall-time limit for one file, run again:\n  test\/web\/b_test.exs: \d+\.\d s\n/
    end

    test "a file over the limit only beside others passes, run again", ctx do
      File.write!(ctx.slow_beside, "test/web/b_test.exs\n")
      write_limits(ctx.base, @over_limits)

      assert {out, 0} = run(ctx)
      assert out =~ ~r/  test\/web\/b_test.exs: \d+\.\d s beside others, \d+\.\d s run again\n/
      assert out =~ "all 3 test files passed"

      assert Enum.count(runs(ctx), &(&1 == "test mix test --no-compile test/web/b_test.exs")) == 2
      assert erl_opts(ctx) == ["compile: unset" | List.duplicate("test: +S 4 +sbwt none ", 4)]
      # No run, first or again, holds the test-file slot's lock open.
      assert lines(ctx.slot_fd) == []
    end

    test "a file that fails when run again fails the run and has its output shown", ctx do
      File.write!(ctx.slow_beside, "test/web/b_test.exs\n")
      File.write!(ctx.failing_alone, "test/web/b_test.exs\n")
      write_limits(ctx.base, @over_limits)

      assert {out, 1} = run(ctx)
      assert out =~ ~r/  test\/web\/b_test.exs: \d+\.\d s beside others; failed when run again\n/

      assert out =~
               "=== mix test test/web/b_test.exs, run again ===\nran test/web/b_test.exs"

      refute out =~ "all 3 test files passed"
    end

    test "no file is run again once a file has failed", ctx do
      File.write!(ctx.slow, "test/a_test.exs\n")
      File.write!(ctx.failing, "test/web/b_test.exs\n")
      write_limits(ctx.base, %{@over_limits | exempt: %{}})

      assert {out, 1} = run(ctx)
      refute out =~ "running again"
      assert out =~ "1 of 3 test files failed:\n  test/web/b_test.exs"
      assert length(runs(ctx)) == 4
    end

    test "a file over the limit with a reason passes and is not run again", ctx do
      File.write!(ctx.slow, "test/web/b_test.exs\n")

      write_limits(ctx.base, %{
        @over_limits
        | exempt: Map.put(@others_exempt, "test/web/b_test.exs", %{reason: "drives a real shell"})
      })

      assert {out, 0} = run(ctx)
      refute out =~ "over the 1 s"
      assert out =~ "all 3 test files passed"
      assert length(runs(ctx)) == 4
    end

    # Each limit is needed in both modes, so a gate catches what CI would.
    for {name, limits, ci, message} <- [
          {"an entry without a reason",
           ~s({"limit_seconds": 60, "cpu_limit_seconds": 10, "exempt": {"test/a_test.exs": {}}}),
           nil, "entry test/a_test.exs needs a non-empty reason."},
          {"an entry with a blank reason",
           ~s({"limit_seconds": 60, "cpu_limit_seconds": 10, "exempt": {"test/a_test.exs": {"reason": " "}}}),
           nil, "entry test/a_test.exs needs a non-empty reason."},
          {"no CPU-time limit", ~s({"limit_seconds": 60, "exempt": {}}), nil,
           "needs a positive cpu_limit_seconds."},
          {"in CI, no CPU-time limit", ~s({"limit_seconds": 60, "exempt": {}}), "true",
           "needs a positive cpu_limit_seconds."},
          {"no wall-time limit", ~s({"cpu_limit_seconds": 10, "exempt": {}}), nil,
           "needs a positive limit_seconds."},
          {"no exempt object", ~s({"limit_seconds": 60, "cpu_limit_seconds": 10}), nil,
           "needs an exempt object."},
          {"malformed JSON", "{", nil, "cannot read scripts/test-file-limit.json"}
        ] do
      test "#{name} fails the run", ctx do
        File.write!(Path.join(ctx.base, "scripts/test-file-limit.json"), unquote(limits))

        assert {out, 1} = run(ctx, [{"CI", unquote(ci)}])
        assert out =~ "scripts/test-file-limit.json"
        assert out =~ unquote(message)
      end
    end

    test "times written with a decimal comma are read and add up exactly", ctx do
      # Added as floats, 1.1 and 0.1 show as 1.3.
      assert {out, 0} = file_times(ctx, "0,5 1,1 0,1")

      assert out =~
               "over the 1 s CPU-time limit beside them:\n  test/web/b_test.exs: 1.2 s beside others, "
    end

    test "a time exactly at the limit passes", ctx do
      assert {out, 0} = file_times(ctx, "0 0.5 0.5")
      refute out =~ "running again"
    end

    test "a fraction of a second over the limit counts, and shows rounded up", ctx do
      assert {out, 0} = file_times(ctx, "0 0.5 0.504")

      assert out =~
               "over the 1 s CPU-time limit beside them:\n  test/web/b_test.exs: 1.1 s beside others, "
    end

    test "times that cannot be read fail the run", ctx do
      for times <- ["", "1.5 x 0.1", "1.5 0.1", "1 1.5 0.1 0.1"] do
        assert {out, 1} = file_times(ctx, times)
        assert out =~ "cannot read the times in"
      end
    end

    test "a missing limits file fails the run", ctx do
      File.rm!(Path.join(ctx.base, "scripts/test-file-limit.json"))

      assert {out, 1} = run(ctx)
      assert out =~ "cannot read scripts/test-file-limit.json"
    end

    test "the repo's limits are 60 s of wall time and 10 s of CPU time, and every exemption has a reason" do
      limits = Path.join(@root, "scripts/test-file-limit.json") |> File.read!() |> Jason.decode!()
      assert limits["limit_seconds"] == 60
      assert limits["cpu_limit_seconds"] == 10

      for {file, entry} <- limits["exempt"] do
        assert File.exists?(Path.join(@root, file)), "#{file} is exempt but does not exist"
        assert String.trim(entry["reason"]) != ""
      end
    end
  end

  defp write_limits(base, limits) do
    File.write!(Path.join(base, "scripts/test-file-limit.json"), Jason.encode!(limits))
  end

  defp write_test_file(base, file) do
    File.mkdir_p!(Path.dirname(Path.join(base, file)))
    File.write!(Path.join(base, file), "")
  end

  defp run(ctx, env \\ []), do: cmd(ctx, "bash", ["scripts/mix-test.sh"], env)

  # Runs test-file-times.ts on its own over test/web/b_test.exs, whose first
  # run's times file holds `times`; its run again is quick.
  defp file_times(ctx, times) do
    write_limits(ctx.base, @over_limits)
    logs = Path.join(ctx.base, "logs")
    File.mkdir_p!(Path.join(logs, "test/web"))
    File.write!(Path.join(logs, "test/web/b_test.exs.secs"), times)
    cmd(ctx, "bun", ["scripts/test-file-times.ts", logs, "1", "test/web/b_test.exs"])
  end

  # This suite's own runner may have set ELIXIR_ERL_OPTIONS and
  # MIX_OS_CONCURRENCY_LOCK, and CI sets CI. hook_env/0 keeps the test-file
  # slots in the fixture's repo when this suite runs in a hook.
  defp cmd(ctx, command, args, env \\ []) do
    env =
      Map.merge(
        %{"ELIXIR_ERL_OPTIONS" => nil, "MIX_OS_CONCURRENCY_LOCK" => nil, "CI" => nil},
        Map.new(env)
      )

    System.cmd(command, args,
      cd: ctx.base,
      env:
        [{"PATH", ctx.stubs <> ":" <> System.fetch_env!("PATH")} | Enum.to_list(env)] ++
          Meerkat.TestHelpers.hook_env(),
      stderr_to_stdout: true
    )
  end

  defp erl_opts(ctx), do: lines(ctx.erl_opts)

  defp runs(ctx), do: lines(ctx.log)

  defp lines(path), do: path |> File.read!() |> String.split("\n", trim: true)

  defp most_at_once(ctx) do
    ctx.spans
    |> lines()
    |> Enum.scan(0, fn
      "start", running -> running + 1
      "end", running -> running - 1
    end)
    |> Enum.max()
  end
end
