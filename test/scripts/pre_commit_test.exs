defmodule Meerkat.PreCommitHookTest do
  # Commits through the repo's real lefthook.yml, scripts/no-main-commits.sh,
  # scripts/check.sh and scripts/mutate.sh. Only the tools those scripts run
  # (mix, pnpm, bun, bunx) are replaced, by stubs on PATH that log each run
  # and can fail it. The `mix muex` stub writes the report STUB_REPORT names,
  # or none when it is `none`, and exits with STUB_MUEX_EXIT.
  use ExUnit.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, stage: 3, hook_env: 0]

  @root File.cwd!()

  # Every gate check.sh runs, in order, as the stubs log it.
  @gates [
    "mix deps.get",
    "pnpm install --frozen-lockfile --ignore-scripts --prefer-offline",
    "mix compile --warnings-as-errors",
    "mix format --check-formatted",
    "mix credo --strict",
    "bunx biome lint --error-on-warnings",
    "mix-test.sh",
    "bun test",
    "bun test tests/e2e/lib",
    "bun run build",
    "bunx playwright install --only-shell chromium",
    "bun run test:e2e"
  ]

  # What scripts/mutate.sh staged runs after the gates.
  @mutation [
    "mix deps.get",
    "pnpm install --frozen-lockfile --ignore-scripts --prefer-offline",
    "mix compile --warnings-as-errors",
    "mix muex"
  ]

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-pre-commit")
    on_exit(fn -> File.rm_rf!(base) end)
    File.rm_rf!(Path.join(base, ".git"))

    work = Path.join(base, "work")
    stubs = Path.join(base, "stubs")
    log = Path.join(base, "log")
    seen = Path.join(base, "seen")
    places = Path.join(base, "places")
    muex = Path.join(base, "muex")

    File.mkdir_p!(Path.join(work, "scripts"))
    git(base, ["init", "-q", "--initial-branch=main", work])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])

    File.cp!(Path.join(@root, "lefthook.yml"), Path.join(work, "lefthook.yml"))

    for script <- ~w(check.sh no-main-commits.sh mutate.sh) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([work, "scripts", script]))
    end

    # test/scripts/bump_deps_test.exs covers the dependency bump.
    File.write!(Path.join([work, "scripts", "bump-deps.sh"]), "exit 0\n")
    # test/scripts/mix_test_test.exs covers the runner itself. Replace this
    # with `exec mix-test.sh` so the PATH stub logs check.sh's test step as
    # `mix-test.sh` and catches a regression to plain `mix test`.
    File.write!(Path.join([work, "scripts", "mix-test.sh"]), "exec mix-test.sh\n")

    File.write!(Path.join(work, ".gitignore"), "node_modules\n")
    File.mkdir_p!(Path.join(work, "assets"))
    File.write!(Path.join(work, "assets/.keep"), "")
    File.write!(Path.join(work, "code.txt"), "base\n")
    File.mkdir_p!(Path.join(work, "lib/meerkat"))
    File.write!(Path.join(work, "lib/meerkat/one.ex"), "one\nbase\n")
    File.write!(Path.join(work, "lib/meerkat/two.ex"), "two\nbase\n")
    git(work, ["add", "-A"])
    no_hooks(work, ["commit", "-qm", "base"])
    no_hooks(work, ["switch", "-q", "-c", "feature"])

    Meerkat.TestHelpers.install_lefthook(work)

    # The stub records where each tool runs and with which MIX_BUILD_PATH,
    # and, for the compile gate, which git variables leak into it. For
    # `mix muex` it records its arguments, the git variables it gets, and
    # the files the index it is given stages, then writes the report.
    File.mkdir_p!(stubs)
    File.mkdir_p!(muex)
    report = write_report(base, "killed", [mutant("killed")])

    File.write!(Path.join(stubs, "stub"), """
    #!/usr/bin/env bash
    if [ "$(basename "$0") $1" = "mix muex" ]; then
      echo "mix muex" >> '#{log}'
      printf '%s\\n' "$@" > '#{muex}/args'
      env | grep '^GIT_' > '#{muex}/env'
      git diff --cached --name-only > '#{muex}/staged'
      while [ $# -gt 0 ] && [ "$1" != --output ]; do shift; done
      [ $# -gt 0 ] || exit 0
      echo "$2" > '#{muex}/output'
      # Like real muex, write no report when there is nothing to mutate.
      [ "${STUB_REPORT:-}" = none ] || cp "${STUB_REPORT:-#{report}}" "$2"
      exit "${STUB_MUEX_EXIT:-0}"
    fi
    cmd="$(basename "$0")${*:+ $*}"
    echo "$cmd" >> '#{log}'
    printf '%s\\t%s\\t%s\\n' "$cmd" "$PWD" "${MIX_BUILD_PATH:-}" >> '#{places}'
    if [ "$cmd" = "mix compile --warnings-as-errors" ]; then
      env | grep '^GIT_' | sed 's/^/env=/' > '#{seen}'
    fi
    [ "$cmd" != "${STUB_FAIL:-}" ]
    """)

    File.chmod!(Path.join(stubs, "stub"), 0o755)
    for tool <- ~w(mix pnpm bun bunx mix-test.sh), do: File.ln_s!("stub", Path.join(stubs, tool))

    {:ok, base: base, work: work, stubs: stubs, log: log, seen: seen, places: places, muex: muex}
  end

  test "a commit runs every gate in the checkout", ctx do
    stage(ctx.work, "code.txt", "staged\n")

    assert {out, 0} = commit(ctx, ["-m", "change code"])
    assert out =~ "all checks passed"
    assert gates_run(ctx) == @gates

    top = git(ctx.work, ["rev-parse", "--show-toplevel"])
    assets = Path.join(top, "assets")
    places = places(ctx)

    for gate <- @gates -- ["bun test", "bun run build"] do
      assert {^top, _} = places[gate], "#{gate} ran outside the checkout root"
    end

    assert {^assets, _} = places["bun test"]
    assert places["bun run build"] == {assets, Path.join(top, "_build/dev")}

    seen = seen(ctx)

    for var <- ~w(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX) do
      refute Enum.any?(seen, &String.starts_with?(&1, "env=#{var}=")), "#{var} leaked"
    end
  end

  test "`git commit -a` runs the checks", ctx do
    File.write!(Path.join(ctx.work, "code.txt"), "all\n")

    assert {_, 0} = commit(ctx, ["-am", "change code"])
    assert gates_run(ctx) == @gates
  end

  for gate <- @gates do
    test "a failing `#{gate}` blocks the commit", ctx do
      head = git(ctx.work, ["rev-parse", "HEAD"])
      stage(ctx.work, "code.txt", "staged\n")

      assert {_, code} = commit(ctx, ["-m", "change code"], [{"STUB_FAIL", unquote(gate)}])
      assert code != 0
      assert git(ctx.work, ["rev-parse", "HEAD"]) == head
      assert List.last(gates_run(ctx)) == unquote(gate)
    end
  end

  test "a commit changing only Markdown files skips the checks", ctx do
    stage(ctx.work, "README.md", "hello\n")
    stage(ctx.work, "docs/guide.md", "guide\n")

    assert {out, 0} = commit(ctx, ["-m", "docs"])
    assert out =~ "skipping checks"
    assert gates_run(ctx) == []
  end

  test "renaming code to a Markdown file runs the checks", ctx do
    git(ctx.work, ["mv", "code.txt", "code.md"])

    assert {_, 0} = commit(ctx, ["-m", "rename"])
    assert gates_run(ctx) == @gates
  end

  test "a commit staging lib/ lines mutates those lines after the checks", ctx do
    stage(ctx.work, "lib/meerkat/one.ex", "one\nchanged\n")

    assert {out, 0} = commit(ctx, ["-m", "change lib"])
    assert out =~ "no mutant of the selected lib/ lines survived"
    assert gates_run(ctx) == @gates ++ @mutation

    args = muex_args(ctx)
    assert "--staged" in args
    assert "--coverage-guided" in args
    assert "--no-filter" in args
    assert "--no-optimize" in args
    assert ["--fail-at", "0"] in Enum.chunk_every(args, 2, 1)
    assert muex_staged(ctx) == ["lib/meerkat/one.ex"]

    # muex prints the report's path, so the report must outlive the run.
    output = ctx.muex |> Path.join("output") |> File.read!() |> String.trim()
    assert File.exists?(output)

    assert String.starts_with?(
             output,
             Path.join(git(ctx.work, ["rev-parse", "--show-toplevel"]), "_build/")
           )

    env = muex_env(ctx)
    assert Enum.any?(env, &String.starts_with?(&1, "GIT_INDEX_FILE=/"))

    for var <- ~w(GIT_DIR GIT_WORK_TREE GIT_PREFIX) do
      refute Enum.any?(env, &String.starts_with?(&1, "#{var}=")), "#{var} leaked"
    end
  end

  # Both hand the hook a temporary index holding exactly the commit's
  # contents; muex must diff that one, not the checkout's own index.
  test "`git commit -a` mutates the lines it commits", ctx do
    File.write!(Path.join(ctx.work, "lib/meerkat/two.ex"), "two\nchanged\n")

    assert {_, 0} = commit(ctx, ["-am", "change lib"])
    assert muex_staged(ctx) == ["lib/meerkat/two.ex"]
  end

  test "`git commit <path>` mutates only the lines of that path", ctx do
    stage(ctx.work, "lib/meerkat/one.ex", "one\nstaged\n")
    File.write!(Path.join(ctx.work, "lib/meerkat/two.ex"), "two\nchanged\n")

    assert {_, 0} = commit(ctx, ["-m", "change two", "--", "lib/meerkat/two.ex"])
    assert muex_staged(ctx) == ["lib/meerkat/two.ex"]
  end

  test "staging only deleted lib/ lines skips mutation testing", ctx do
    stage(ctx.work, "lib/meerkat/one.ex", "one\n")

    assert {out, 0} = commit(ctx, ["-m", "delete a line"])
    assert out =~ "nothing to mutate"
    assert gates_run(ctx) == @gates
  end

  for status <- ~w(survived no_coverage) do
    test "a #{status} mutant blocks the commit and is listed", ctx do
      head = git(ctx.work, ["rev-parse", "HEAD"])
      stage(ctx.work, "lib/meerkat/one.ex", "one\nchanged\n")

      report =
        write_report(ctx.base, unquote(status), [mutant("killed"), mutant(unquote(status))])

      assert {out, code} = commit(ctx, ["-m", "change lib"], [{"STUB_REPORT", report}])
      assert code != 0
      assert git(ctx.work, ["rev-parse", "HEAD"]) == head
      assert out =~ "lib/meerkat/one.ex:2  #{unquote(status)}  Comparison: == to !="
      assert out =~ "    - a == b"
      assert out =~ "    + a != b"
      refute out =~ "  killed  "
    end
  end

  test "killed, timed-out, invalid, equivalent and ignored mutants pass", ctx do
    stage(ctx.work, "lib/meerkat/one.ex", "one\nchanged\n")
    statuses = ~w(killed timeout invalid equivalent ignored)
    report = write_report(ctx.base, "passing", Enum.map(statuses, &mutant/1))

    assert {_, 0} = commit(ctx, ["-m", "change lib"], [{"STUB_REPORT", report}])
  end

  # muex writes no report then, so an earlier run's report must not be judged.
  test "a staged line with no mutants passes, whatever an earlier run reported", ctx do
    stage(ctx.work, "lib/meerkat/one.ex", "one\n# comment\n")
    stale = write_report(ctx.base, "stale", [mutant("survived")])
    File.mkdir_p!(Path.join(ctx.work, "_build"))
    File.cp!(stale, Path.join(ctx.work, "_build/mutate.json"))

    assert {out, 0} = commit(ctx, ["-m", "comment"], [{"STUB_REPORT", "none"}])
    assert out =~ "produce no mutants"
    assert gates_run(ctx) == @gates ++ @mutation
  end

  test "a failed muex run blocks the commit", ctx do
    head = git(ctx.work, ["rev-parse", "HEAD"])
    stage(ctx.work, "lib/meerkat/one.ex", "one\nchanged\n")

    assert {_, code} = commit(ctx, ["-m", "change lib"], [{"STUB_MUEX_EXIT", "1"}])
    assert code != 0
    assert git(ctx.work, ["rev-parse", "HEAD"]) == head
  end

  test "a mutant status the gate does not know blocks the commit", ctx do
    stage(ctx.work, "lib/meerkat/one.ex", "one\nchanged\n")
    report = write_report(ctx.base, "unknown", [mutant("killed"), mutant("pending")])

    assert {out, code} = commit(ctx, ["-m", "change lib"], [{"STUB_REPORT", report}])
    assert code != 0
    assert out =~ "unknown mutant status(es): pending"
  end

  test "an external diff tool does not hide staged lib/ lines", ctx do
    stage(ctx.work, "lib/meerkat_web/live/view.ex", "view\n")

    assert {_, 0} = commit(ctx, ["-m", "add view"], [{"GIT_EXTERNAL_DIFF", "true"}])
    assert gates_run(ctx) == @gates ++ @mutation
    assert muex_staged(ctx) == ["lib/meerkat_web/live/view.ex"]
  end

  # `changed` scores the same lines a commit would, so it must keep every
  # mutant the gate keeps.
  test "`mutate.sh changed` mutates uncommitted lib/ lines with the gate's scoping", ctx do
    File.write!(Path.join(ctx.work, "lib/meerkat/one.ex"), "one\nchanged\n")
    path = ctx.stubs <> ":" <> System.fetch_env!("PATH")

    assert {_, 0} =
             System.cmd("bash", ["scripts/mutate.sh", "changed"],
               cd: ctx.work,
               env: [{"PATH", path}, {"BASE_BRANCH", "main"}],
               stderr_to_stdout: true
             )

    args = muex_args(ctx)
    assert ["--since", "main"] in Enum.chunk_every(args, 2, 1)
    assert "--no-filter" in args
    assert "--no-optimize" in args
  end

  # muex's own exit status passes survivors under its default --fail-at
  # and ignores no-coverage mutants, so every mode judges the report.
  for status <- ~w(survived no_coverage) do
    test "`mutate.sh <path>` fails on a #{status} mutant and lists it", ctx do
      report = write_report(ctx.base, unquote(status), [mutant(unquote(status))])
      path = ctx.stubs <> ":" <> System.fetch_env!("PATH")

      assert {out, 1} =
               System.cmd("bash", ["scripts/mutate.sh", "lib/meerkat/one.ex"],
                 cd: ctx.work,
                 env: [{"PATH", path}, {"STUB_REPORT", report}],
                 stderr_to_stdout: true
               )

      assert out =~ "lib/meerkat/one.ex:2  #{unquote(status)}  Comparison: == to !="
      assert "--fail-at" in muex_args(ctx)
    end
  end

  test "a commit on main is refused before any check runs", ctx do
    no_hooks(ctx.work, ["switch", "-q", "main"])
    stage(ctx.work, "code.txt", "staged\n")

    assert {_, code} = commit(ctx, ["-m", "on main"])
    assert code != 0
    assert gates_run(ctx) == []
  end

  test "the root commit of an orphan branch runs the checks", ctx do
    no_hooks(ctx.work, ["checkout", "-q", "--orphan", "fresh"])

    # A root commit stages every file, the Elixir under lib/meerkat included.
    assert {_, 0} = commit(ctx, ["-m", "root"])
    assert gates_run(ctx) == @gates ++ @mutation
    assert git(ctx.work, ["rev-list", "--count", "HEAD"]) == "1"
  end

  test "a commit on a detached HEAD runs the checks", ctx do
    no_hooks(ctx.work, ["switch", "-q", "--detach"])
    stage(ctx.work, "code.txt", "staged\n")

    assert {_, 0} = commit(ctx, ["-m", "detached"])
    assert gates_run(ctx) == @gates
  end

  defp commit(ctx, args, env \\ []) do
    path = ctx.stubs <> ":" <> System.fetch_env!("PATH")

    System.cmd("git", ["commit", "-q" | args],
      cd: ctx.work,
      env: [{"PATH", path} | hook_env()] ++ env,
      stderr_to_stdout: true
    )
  end

  defp gates_run(ctx) do
    case File.read(ctx.log) do
      {:ok, log} -> String.split(log, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp seen(ctx), do: ctx.seen |> File.read!() |> String.split("\n", trim: true)

  defp muex_args(ctx), do: read_lines(Path.join(ctx.muex, "args"))
  defp muex_env(ctx), do: read_lines(Path.join(ctx.muex, "env"))
  defp muex_staged(ctx), do: read_lines(Path.join(ctx.muex, "staged"))
  defp read_lines(path), do: path |> File.read!() |> String.split("\n", trim: true)

  # A mutant in the shape of muex's JSON report.
  defp mutant(status) do
    %{
      status: status,
      description: "Comparison: == to !=",
      location: %{file: "lib/meerkat/one.ex", line: 2},
      patch: %{before: "a == b", after: "a != b"}
    }
  end

  defp write_report(base, name, mutations) do
    path = Path.join(base, "report-#{name}.json")
    File.write!(path, Jason.encode!(%{summary: %{}, mutations: mutations}))
    path
  end

  defp places(ctx) do
    for line <- ctx.places |> File.read!() |> String.split("\n", trim: true), into: %{} do
      [cmd, pwd, build_path] = String.split(line, "\t")
      {cmd, {pwd, build_path}}
    end
  end

  # Only commits go through the hooks; other commands would fire lefthook's
  # post-checkout install, whose script this fixture leaves out.
  defp no_hooks(work, args), do: git(work, ["-c", "core.hooksPath=/dev/null" | args])
end
