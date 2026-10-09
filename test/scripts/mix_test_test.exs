defmodule Meerkat.MixTestScriptTest do
  # Runs the repo's real scripts/mix-test.sh in a temporary directory against
  # a fixture tree of empty test files; only mix and getconf are PATH stubs.
  # The mix stub logs each run, records each test-file run's start and end,
  # sleeps for a test-set delay, prints the file to stdout and stderr, and
  # can fail compile or files named by a test, or kill their jobs. The getconf stub reports a
  # test-set core count.
  use ExUnit.Case, async: true

  @root File.cwd!()

  @files ~w(test/a_test.exs test/web/b_test.exs test/c_test.exs)

  setup do
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-mix-test")
    on_exit(fn -> File.rm_rf!(base) end)

    stubs = Path.join(base, "stubs")
    log = Path.join(base, "log")
    erl_opts = Path.join(base, "erl_opts")
    spans = Path.join(base, "spans")
    failing = Path.join(base, "failing")
    killed = Path.join(base, "killed")
    cores = Path.join(base, "cores")
    delay = Path.join(base, "delay")

    File.mkdir_p!(Path.join(base, "scripts"))
    File.cp!(Path.join(@root, "scripts/mix-test.sh"), Path.join(base, "scripts/mix-test.sh"))

    for file <- @files, do: write_test_file(base, file)

    File.write!(Path.join(base, "test/test_helper.exs"), "")
    File.write!(failing, "")
    File.write!(killed, "")
    File.write!(cores, "4\n")
    File.write!(delay, "0\n")

    File.mkdir_p!(stubs)

    File.write!(Path.join(stubs, "mix"), """
    #!/usr/bin/env bash
    echo "$MIX_ENV mix $*" >> '#{log}'
    echo "$1: ${ELIXIR_ERL_OPTIONS-unset}" >> '#{erl_opts}'
    if [ "$1" = compile ]; then ! grep -qxF compile '#{failing}'; exit; fi
    if grep -qxF "$3" '#{killed}'; then kill -9 "$PPID"; exit 1; fi
    echo "start" >> '#{spans}'
    sleep "$(cat '#{delay}')"
    echo "end" >> '#{spans}'
    echo "ran $3"
    echo "err $3" >&2
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
     killed: killed,
     cores: cores,
     delay: delay}
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

  defp write_test_file(base, file) do
    File.mkdir_p!(Path.dirname(Path.join(base, file)))
    File.write!(Path.join(base, file), "")
  end

  # This suite's own runner may have set ELIXIR_ERL_OPTIONS.
  defp run(ctx, env \\ [{"ELIXIR_ERL_OPTIONS", nil}]) do
    System.cmd("bash", ["scripts/mix-test.sh"],
      cd: ctx.base,
      env: [{"PATH", ctx.stubs <> ":" <> System.fetch_env!("PATH")} | env],
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
