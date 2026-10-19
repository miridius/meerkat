defmodule Meerkat.MixTestScriptTest do
  # Runs the repo's real scripts/mix-test.sh, with the scripts it runs, in a
  # temporary git repo against a fixture tree of empty test files; only mix
  # and getconf are PATH stubs. The mix stub logs each run, records each
  # test-file run's start and end, sleeps for a test-set delay, and three
  # seconds more for files named as slow, or named as slow beside others on
  # their first run only, prints the file to stdout and stderr, and can fail
  # compile or files named by a test, or kill their jobs. The getconf stub
  # reports a test-set core count. The per-file time limit is 60 s, so only
  # the over-limit tests, which set it to two seconds, can hit it.
  use ExUnit.Case, async: true

  @root File.cwd!()

  @files ~w(test/a_test.exs test/web/b_test.exs test/c_test.exs)

  setup do
    base = Meerkat.TestHelpers.make_git_repo("meerkat-mix-test")
    on_exit(fn -> File.rm_rf!(base) end)

    stubs = Path.join(base, "stubs")
    log = Path.join(base, "log")
    erl_opts = Path.join(base, "erl_opts")
    spans = Path.join(base, "spans")
    failing = Path.join(base, "failing")
    failing_alone = Path.join(base, "failing_alone")
    killed = Path.join(base, "killed")
    cores = Path.join(base, "cores")
    delay = Path.join(base, "delay")
    slow = Path.join(base, "slow")
    slow_beside = Path.join(base, "slow_beside")
    seen = Path.join(base, "seen")

    File.mkdir_p!(Path.join(base, "scripts"))

    for script <- ~w(mix-test.sh run-test-file.sh gate-lock.sh test-file-times.ts) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([base, "scripts", script]))
    end

    write_limits(base, %{limit_seconds: 60, exempt: %{}})

    for file <- @files, do: write_test_file(base, file)

    File.write!(Path.join(base, "test/test_helper.exs"), "")

    for file <- [failing, failing_alone, killed, slow, slow_beside, seen],
        do: File.write!(file, "")

    File.write!(cores, "4\n")
    File.write!(delay, "0\n")

    File.mkdir_p!(stubs)

    # A file's second run is its run on its own; the job a stub kills is
    # run-test-file.sh's parent.
    File.write!(Path.join(stubs, "mix"), """
    #!/usr/bin/env bash
    echo "$MIX_ENV mix $*" >> '#{log}'
    echo "$1: ${ELIXIR_ERL_OPTIONS-unset}" >> '#{erl_opts}'
    if [ "$1" = compile ]; then ! grep -qxF compile '#{failing}'; exit; fi
    if grep -qxF "$3" '#{killed}'; then kill -9 $(ps -o ppid= -p "$PPID"); exit 1; fi
    alone=false
    if grep -qxF "$3" '#{seen}'; then alone=true; else echo "$3" >> '#{seen}'; fi
    echo "start" >> '#{spans}'
    sleep "$(cat '#{delay}')"
    if grep -qxF "$3" '#{slow}'; then sleep 3; fi
    if [ $alone = false ] && grep -qxF "$3" '#{slow_beside}'; then sleep 3; fi
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
     spans: spans,
     failing: failing,
     failing_alone: failing_alone,
     killed: killed,
     cores: cores,
     delay: delay,
     slow: slow,
     slow_beside: slow_beside}
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

  test "two runs at once share half the cores' worth of slots, waiting silently", ctx do
    File.write!(ctx.cores, "4\n")
    File.write!(ctx.delay, "0.5\n")

    runs = for _ <- 1..2, do: Task.async(fn -> run(ctx) end)

    for {out, status} <- Task.await_many(runs, :infinity) do
      assert status == 0
      refute out =~ "gate-lock"
    end

    assert most_at_once(ctx) == 2
  end

  describe "the per-file time limit" do
    test "a file over the limit on its own fails the run and is named", ctx do
      File.write!(ctx.slow, "test/web/b_test.exs\n")
      write_limits(ctx.base, %{limit_seconds: 2, exempt: %{}})

      assert {out, 1} = run(ctx)

      assert out =~ ~r/  test\/web\/b_test.exs: \d+ s beside others, \d+ s alone\n/

      assert out =~
               ~r/test files over the 2 s limit for one file, run on their own:\n  test\/web\/b_test.exs: \d+ s\n/

      refute out =~ "a_test.exs: "
      refute out =~ "all 3 test files passed"
    end

    test "a file over the limit only beside others passes, run again on its own", ctx do
      File.write!(ctx.slow_beside, "test/web/b_test.exs\n")
      write_limits(ctx.base, %{limit_seconds: 2, exempt: %{}})

      assert {out, 0} = run(ctx)
      assert out =~ ~r/  test\/web\/b_test.exs: \d+ s beside others, \d+ s alone\n/
      assert out =~ "all 3 test files passed"

      assert Enum.count(runs(ctx), &(&1 == "test mix test --no-compile test/web/b_test.exs")) == 2
      assert erl_opts(ctx) == ["compile: unset" | List.duplicate("test: +S 4 +sbwt none ", 4)]
    end

    test "a file that fails when run again on its own fails the run and has its output shown",
         ctx do
      File.write!(ctx.slow_beside, "test/web/b_test.exs\n")
      File.write!(ctx.failing_alone, "test/web/b_test.exs\n")
      write_limits(ctx.base, %{limit_seconds: 2, exempt: %{}})

      assert {out, 1} = run(ctx)
      assert out =~ ~r/  test\/web\/b_test.exs: \d+ s beside others; failed on its own\n/

      assert out =~
               "=== mix test test/web/b_test.exs, run again on its own ===\nran test/web/b_test.exs"

      refute out =~ "all 3 test files passed"
    end

    test "a file over the limit that failed is not run again", ctx do
      File.write!(ctx.slow, "test/web/b_test.exs\n")
      File.write!(ctx.failing, "test/web/b_test.exs\n")
      write_limits(ctx.base, %{limit_seconds: 2, exempt: %{}})

      assert {out, 1} = run(ctx)
      refute out =~ "running again"
      assert out =~ "1 of 3 test files failed:\n  test/web/b_test.exs"
      assert length(runs(ctx)) == 4
    end

    test "a file over the limit with a reason passes and is not run again", ctx do
      File.write!(ctx.slow, "test/web/b_test.exs\n")

      write_limits(ctx.base, %{
        limit_seconds: 2,
        exempt: %{"test/web/b_test.exs" => %{reason: "drives a real shell"}}
      })

      assert {out, 0} = run(ctx)
      refute out =~ "over the 2 s limit"
      assert out =~ "all 3 test files passed"
      assert length(runs(ctx)) == 4
    end

    for {name, limits} <- [
          {"an entry without a reason",
           ~s({"limit_seconds": 60, "exempt": {"test/a_test.exs": {}}})},
          {"an entry with a blank reason",
           ~s({"limit_seconds": 60, "exempt": {"test/a_test.exs": {"reason": " "}}})},
          {"no limit", ~s({"exempt": {}})},
          {"no exempt object", ~s({"limit_seconds": 60})},
          {"malformed JSON", "{"}
        ] do
      test "#{name} fails the run", ctx do
        File.write!(Path.join(ctx.base, "scripts/test-file-limit.json"), unquote(limits))

        assert {out, 1} = run(ctx)
        assert out =~ "scripts/test-file-limit.json"
      end
    end

    test "a missing limits file fails the run", ctx do
      File.rm!(Path.join(ctx.base, "scripts/test-file-limit.json"))

      assert {out, 1} = run(ctx)
      assert out =~ "cannot read scripts/test-file-limit.json"
    end

    test "the repo's limit is 60 s and every exemption has a reason" do
      limits = Path.join(@root, "scripts/test-file-limit.json") |> File.read!() |> Jason.decode!()
      assert limits["limit_seconds"] == 60

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

  # This suite's own runner may have set ELIXIR_ERL_OPTIONS. hook_env/0 keeps
  # the test-file slots in the fixture's repo when this suite runs in a hook.
  defp run(ctx, env \\ [{"ELIXIR_ERL_OPTIONS", nil}]) do
    System.cmd("bash", ["scripts/mix-test.sh"],
      cd: ctx.base,
      env:
        [{"PATH", ctx.stubs <> ":" <> System.fetch_env!("PATH")} | env] ++
          Meerkat.TestHelpers.hook_env(),
      stderr_to_stdout: true
    )
  end

  defp erl_opts(ctx), do: ctx.erl_opts |> File.read!() |> String.split("\n", trim: true)

  defp runs(ctx), do: ctx.log |> File.read!() |> String.split("\n", trim: true)

  defp most_at_once(ctx) do
    ctx.spans
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.scan(0, fn
      "start", running -> running + 1
      "end", running -> running - 1
    end)
    |> Enum.max()
  end
end
