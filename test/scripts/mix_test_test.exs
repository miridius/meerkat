defmodule Meerkat.MixTestScriptTest do
  # Runs the repo's real scripts/mix-test.sh against a fixture test tree.
  # Only mix is replaced, by a stub on PATH that logs each run, prints which
  # file it ran, and fails the files a test names.
  use ExUnit.Case, async: true

  @root File.cwd!()

  @files ~w(test/a_test.exs test/web/b_test.exs test/c_test.exs)

  setup do
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-mix-test")
    on_exit(fn -> File.rm_rf!(base) end)

    stubs = Path.join(base, "stubs")
    log = Path.join(base, "log")
    failing = Path.join(base, "failing")

    File.mkdir_p!(Path.join(base, "scripts"))
    File.cp!(Path.join(@root, "scripts/mix-test.sh"), Path.join(base, "scripts/mix-test.sh"))

    for file <- @files do
      File.mkdir_p!(Path.dirname(Path.join(base, file)))
      File.write!(Path.join(base, file), "")
    end

    File.write!(Path.join(base, "test/test_helper.exs"), "")
    File.write!(failing, "")

    File.mkdir_p!(stubs)

    File.write!(Path.join(stubs, "mix"), """
    #!/usr/bin/env bash
    echo "$MIX_ENV mix $*" >> '#{log}'
    [ "$1" = test ] || exit 0
    echo "ran $3"
    ! grep -qxF "$3" '#{failing}'
    """)

    File.chmod!(Path.join(stubs, "mix"), 0o755)

    {:ok, base: base, stubs: stubs, log: log, failing: failing}
  end

  test "compiles once, then runs every test file in its own mix test", ctx do
    assert {out, 0} = run(ctx)
    assert out =~ "all 3 test files passed"

    [compile | tests] = runs(ctx)
    assert compile == "test mix compile"
    assert Enum.sort(tests) == Enum.sort(for f <- @files, do: "test mix test --no-compile #{f}")
  end

  test "a failing file fails the run and has its output shown", ctx do
    File.write!(ctx.failing, "test/web/b_test.exs\n")

    assert {out, 1} = run(ctx)
    assert out =~ "=== mix test test/web/b_test.exs ===\nran test/web/b_test.exs"
    refute out =~ "ran test/a_test.exs"
    assert out =~ "1 of 3 test files failed:\n  test/web/b_test.exs"
    assert length(runs(ctx)) == 4
  end

  defp run(ctx) do
    System.cmd("bash", ["scripts/mix-test.sh"],
      cd: ctx.base,
      env: [{"PATH", ctx.stubs <> ":" <> System.fetch_env!("PATH")}],
      stderr_to_stdout: true
    )
  end

  defp runs(ctx), do: ctx.log |> File.read!() |> String.split("\n", trim: true)
end
