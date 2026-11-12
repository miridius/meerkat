defmodule Meerkat.PreCommitHookTest do
  # Commits through the repo's real lefthook.yml, scripts/no-main-commits.ts,
  # scripts/check.ts and scripts/mutate.ts. Only the tools those scripts run
  # (mix, pnpm, bun, bunx) are replaced, by stubs on PATH that log each run
  # and can fail it. The `mix muex` stub writes the report STUB_REPORT names,
  # or none when it is `none`. The scripts' logic is unit-tested beside them,
  # in scripts/*.test.ts; the tests here cover only their seams with git,
  # lefthook, the gate slots, the file system and signals.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, stage: 3, hook_env: 0, hold_gate_slot: 1]

  @root File.cwd!()

  # Every gate check.ts runs, in order, as the stubs log it.
  @gates [
    "mix deps.get",
    "bun scripts/hex-audit.ts",
    "pnpm audit",
    "pnpm install --frozen-lockfile --ignore-scripts --prefer-offline",
    "mix compile --warnings-as-errors",
    "mix format --check-formatted",
    "mix credo --strict",
    "bunx biome lint --error-on-warnings",
    "bun scripts/mix-test.ts",
    "bun test",
    "bun test tests/e2e/lib",
    "bun test scripts",
    "bun run build",
    "bunx playwright install --only-shell chromium",
    "bun run test:e2e"
  ]

  # What scripts/mutate.ts staged runs after the gates.
  @mutation [
    "mix deps.get",
    "pnpm install --frozen-lockfile --ignore-scripts --prefer-offline",
    "mix compile --warnings-as-errors",
    "mix muex"
  ]

  # Built once, then copied for each test.
  setup_all do
    template =
      Meerkat.TestHelpers.fixture_template("meerkat-pre-commit-template", &build_fixture/1)

    {:ok, template: template}
  end

  setup %{template: template} do
    base = Meerkat.TestHelpers.copy_fixture(template, "meerkat-pre-commit")

    {:ok,
     base: base,
     work: Path.join(base, "work"),
     stubs: Path.join(base, "stubs"),
     log: Path.join(base, "log"),
     seen: Path.join(base, "seen"),
     places: Path.join(base, "places"),
     muex: Path.join(base, "muex"),
     slot_fd: Path.join(base, "slot_fd")}
  end

  defp build_fixture(base) do
    work = Path.join(base, "work")
    stubs = Path.join(base, "stubs")
    log = Path.join(base, "log")
    seen = Path.join(base, "seen")
    places = Path.join(base, "places")
    muex = Path.join(base, "muex")
    slot_fd = Path.join(base, "slot_fd")

    File.mkdir_p!(Path.join(work, "scripts"))
    git(base, ["init", "-q", "--initial-branch=main", work])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])

    File.cp!(Path.join(@root, "lefthook.yml"), Path.join(work, "lefthook.yml"))

    for script <-
          ~w(check.ts checked-trees.ts e2e-inputs.ts gate-lock.sh gate-run.sh no-main-commits.ts
             mutate.ts) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([work, "scripts", script]))
    end

    # test/scripts/bump_deps_test.exs covers the dependency bump, which the
    # bun stub below skips.

    # As in the repo, the mutation gate's report under _build/ is ignored.
    File.write!(Path.join(work, ".gitignore"), "node_modules\n_build\n")
    File.mkdir_p!(Path.join(work, "assets"))
    File.write!(Path.join(work, "assets/.keep"), "")
    File.write!(Path.join(work, "code.txt"), "base\n")
    File.mkdir_p!(Path.join(work, "lib/meerkat"))
    File.write!(Path.join(work, "lib/meerkat/one.ex"), "one\nbase\n")
    File.write!(Path.join(work, "lib/meerkat/two.ex"), "two\nbase\n")

    for test <- ~w(test/meerkat/one_test.exs test/web/two_test.exs test/scripts/gate_test.exs) do
      File.mkdir_p!(Path.join(work, Path.dirname(test)))
      File.write!(Path.join(work, test), "")
    end

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
    # The real bun runs the gates' own scripts.
    case "$(basename "$0") ${1:-}" in
    "bun scripts/check.ts" | "bun scripts/checked-trees.ts" | "bun scripts/no-main-commits.ts" | "bun scripts/mutate.ts")
      exec '#{System.find_executable("bun")}' "$@" ;;
    "bun scripts/bump-deps.ts") exit 0 ;;
    esac
    # With STUB_PROBE_SLOTS set, log each tool that runs while it, or a
    # process between it and the gate, holds a gate slot too: that process
    # would keep the slot if it outlived the gate.
    if [ -n "${STUB_PROBE_SLOTS:-}" ]; then
      holders=" $(lsof -t '#{work}/.git/meerkat-gate-lock/slot1' \\
        '#{work}/.git/meerkat-gate-lock/slot2' 2>/dev/null | tr '\\n' ' ') "
      n=0
      p=$$
      while [ "$p" -gt 1 ]; do
        case "$holders" in *" $p "*) n=$((n + 1)) ;; esac
        p=$(ps -o ppid= -p "$p" | tr -d ' ')
        p=${p:-0}
      done
      [ "$n" -le 1 ] || echo "$(basename "$0") $1" >> '#{slot_fd}'
    fi
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
      if [ "${STUB_INTERRUPT:-}" = "mix muex" ]; then
        trap 'exit 0' INT
        kill -INT 0
      fi
      exit 0
    fi
    cmd="$(basename "$0")${*:+ $*}"
    echo "$cmd" >> '#{log}'
    printf '%s\\t%s\\t%s\\n' "$cmd" "$PWD" "${MIX_BUILD_PATH:-}" >> '#{places}'
    if [ "$cmd" = "mix compile --warnings-as-errors" ]; then
      env | grep '^GIT_' | sed 's/^/env=/' > '#{seen}'
    fi
    # Like the BEAM after Ctrl-C: its process group gets the interrupt, and
    # this step handles it and exits 0.
    if [ "$cmd" = "${STUB_INTERRUPT:-}" ]; then
      trap 'exit 0' INT
      kill -INT 0
    fi
    [ "$cmd" != "${STUB_FAIL:-}" ]
    """)

    File.chmod!(Path.join(stubs, "stub"), 0o755)
    for tool <- ~w(mix pnpm bun bunx), do: File.ln_s!("stub", Path.join(stubs, tool))
  end

  test "a commit runs every gate in the checkout and records its contents", ctx do
    stage(ctx.work, "code.txt", "staged\n")
    refute checked?(ctx, ":")

    assert {out, 0} = commit(ctx, ["-m", "change code"])
    assert out =~ "all checks passed"
    assert gates_run(ctx) == @gates
    assert checked?(ctx, "HEAD")
    assert e2e_checked?(ctx, "HEAD")

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
    assert checked?(ctx, "HEAD")
  end

  # The checks ran on the worktree, which then differs from the commit.
  test "a commit beside an unstaged file or an untracked file is not recorded", ctx do
    stage(ctx.work, "code.txt", "staged\n")
    File.write!(Path.join(ctx.work, "assets/.keep"), "unstaged\n")
    assert {_, 0} = commit(ctx, ["-m", "beside an unstaged file"])
    refute checked?(ctx, "HEAD")

    no_hooks(ctx.work, ["checkout", "--", "assets/.keep"])
    stage(ctx.work, "code.txt", "staged again\n")
    File.write!(Path.join(ctx.work, "new.txt"), "untracked\n")
    assert {_, 0} = commit(ctx, ["-m", "beside an untracked file"])
    refute checked?(ctx, "HEAD")
  end

  # lefthook hides the unstaged part of a partially staged file while the
  # hook runs, so the checks see exactly the commit.
  test "a commit of a partially staged file is recorded", ctx do
    stage(ctx.work, "code.txt", "staged\n")
    File.write!(Path.join(ctx.work, "code.txt"), "unstaged\n")

    assert {_, 0} = commit(ctx, ["-m", "partial"])
    assert checked?(ctx, "HEAD")
    assert File.read!(Path.join(ctx.work, "code.txt")) == "unstaged\n"
  end

  test "a failing check blocks the commit, which is not recorded", ctx do
    head = git(ctx.work, ["rev-parse", "HEAD"])
    stage(ctx.work, "code.txt", "staged\n")

    assert {_, code} = commit(ctx, ["-m", "change code"], [{"STUB_FAIL", "bun run test:e2e"}])
    assert code != 0
    assert git(ctx.work, ["rev-parse", "HEAD"]) == head
    assert gates_run(ctx) == @gates
    refute checked?(ctx, ":")
    refute e2e_checked?(ctx, ":")
  end

  describe "check.ts --head" do
    setup ctx do
      stage(ctx.work, "code.txt", "merged\n")
      no_hooks(ctx.work, ["commit", "-qm", "a merge skips the pre-commit hook"])
      :ok
    end

    test "stops at an interrupt the interrupted step handled, records nothing, and stops its caller",
         ctx do
      # In its own process group, so the stub's interrupt reaches only this job.
      driver = """
      set -m
      { bun scripts/check.ts --head; echo "caller carried on after $1"; } &
      wait $!
      """

      path = ctx.stubs <> ":" <> System.fetch_env!("PATH")
      env = [{"PATH", path}, {"STUB_INTERRUPT", "mix credo --strict"} | hook_env()]

      assert {out, code} =
               System.cmd("bash", ["-c", driver, "driver", "check.ts"],
                 cd: ctx.work,
                 env: env,
                 stderr_to_stdout: true
               )

      assert code != 0
      refute out =~ "caller carried on after check.ts"
      assert List.last(gates_run(ctx)) == "mix credo --strict"
      refute checked?(ctx, "HEAD")
    end
  end

  test "no step of either gate runs where a process other than the gate holds its slot",
       ctx do
    stage(ctx.work, "lib/meerkat/one.ex", "one\nchanged\n")

    assert {_, 0} = commit(ctx, ["-m", "change lib"], [{"STUB_PROBE_SLOTS", "1"}])
    assert gates_run(ctx) == @gates ++ @mutation
    assert File.read(ctx.slot_fd) == {:error, :enoent}
  end

  test "a commit staging lib/ lines mutates those lines after the checks and records them",
       ctx do
    track_main(ctx.work)
    stage(ctx.work, "lib/meerkat/one.ex", "one\nchanged\n")

    assert {out, 0} = commit(ctx, ["-m", "change lib"])
    assert out =~ "no mutant of the staged lib/ lines survived"
    assert gates_run(ctx) == @gates ++ @mutation
    assert "--staged" in muex_args(ctx)
    assert muex_staged(ctx) == ["lib/meerkat/one.ex"]

    # The test files that drive scripts in subprocesses are left out.
    assert ["--test-paths", "test/meerkat/one_test.exs,test/web/two_test.exs"] in Enum.chunk_every(
             muex_args(ctx),
             2,
             1
           )

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

    # HEAD is on origin/main, so every lib line of the commit passed.
    assert mutated?(ctx, "HEAD")
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

  test "a surviving mutant in muex's report blocks the commit, which records nothing", ctx do
    track_main(ctx.work)
    head = git(ctx.work, ["rev-parse", "HEAD"])
    stage(ctx.work, "lib/meerkat/one.ex", "one\nchanged\n")
    report = write_report(ctx.base, "survived", [mutant("killed"), mutant("survived")])

    assert {out, code} = commit(ctx, ["-m", "change lib"], [{"STUB_REPORT", report}])
    assert code != 0
    assert git(ctx.work, ["rev-parse", "HEAD"]) == head
    assert out =~ "lib/meerkat/one.ex:2  survived  Comparison: == to !="
    refute mutated?(ctx, ":")
  end

  # muex writes no report then, so an earlier run's report must not be judged.
  test "a staged line with no mutants passes, whatever an earlier run reported", ctx do
    stage(ctx.work, "lib/meerkat/one.ex", "one\n# comment\n")
    stale = write_report(ctx.base, "stale", [mutant("survived")])
    File.mkdir_p!(Path.join(ctx.work, "_build"))
    File.cp!(stale, Path.join(ctx.work, "_build/mutate-staged.json"))

    assert {out, 0} = commit(ctx, ["-m", "comment"], [{"STUB_REPORT", "none"}])
    assert out =~ "produce no mutants"
    assert gates_run(ctx) == @gates ++ @mutation
  end

  test "an external diff tool does not hide staged lib/ lines", ctx do
    stage(ctx.work, "lib/meerkat_web/live/view.ex", "view\n")

    assert {_, 0} = commit(ctx, ["-m", "add view"], [{"GIT_EXTERNAL_DIFF", "true"}])
    assert gates_run(ctx) == @gates ++ @mutation
    assert muex_staged(ctx) == ["lib/meerkat_web/live/view.ex"]
  end

  # muex finds nothing to mutate in a path that is not a lib/**/*.ex file
  # and writes no report, which would pass.
  test "`mutate.ts <path>` refuses a path that is not a lib/**/*.ex file, and mutates those that are",
       ctx do
    path = ctx.stubs <> ":" <> System.fetch_env!("PATH")
    run = &System.cmd("bun", ["scripts/mutate.ts" | &1], cd: ctx.work, env: [{"PATH", path}])

    assert {out, 2} =
             System.cmd(
               "bun",
               ["scripts/mutate.ts", "lib/meerkat/one.ex", "lib/meerkat/gti.ex", "code.txt"],
               cd: ctx.work,
               env: [{"PATH", path}],
               stderr_to_stdout: true
             )

    assert out =~ "lib/meerkat/gti.ex is not a lib/**/*.ex file"
    assert out =~ "code.txt is not a lib/**/*.ex file"
    refute out =~ "lib/meerkat/one.ex is not"
    refute File.exists?(Path.join(ctx.muex, "args"))

    assert {_, 0} = run.(["lib/meerkat/one.ex", "lib/meerkat/two.ex"])

    assert ["--files", "lib/meerkat/one.ex,lib/meerkat/two.ex"] in Enum.chunk_every(
             muex_args(ctx),
             2,
             1
           )
  end

  describe "while two other gates run" do
    setup ctx do
      {:ok, first: hold_gate_slot(ctx.work), second: hold_gate_slot(ctx.work)}
    end

    test "a commit waits, saying so, then runs every gate once one ends", ctx do
      stage(ctx.work, "code.txt", "staged\n")
      port = in_port(ctx, ["git", "commit", "-q", "-m", "change code"])

      await_line(port, "waiting for one of this repo's 2 gate slots")
      refute_receive {^port, {:exit_status, _}}, 1_000
      assert gates_run(ctx) == []

      Port.close(ctx.first)
      assert_receive {^port, {:exit_status, 0}}
      assert gates_run(ctx) == @gates
    end

    test "staged mutation testing waits, saying so, then runs once a gate ends", ctx do
      stage(ctx.work, "lib/meerkat/one.ex", "one\nchanged\n")
      port = in_port(ctx, ["bun", "scripts/mutate.ts", "staged"])

      await_line(port, "waiting for one of this repo's 2 gate slots")
      refute_receive {^port, {:exit_status, _}}, 1_000
      assert gates_run(ctx) == []

      Port.close(ctx.second)
      assert_receive {^port, {:exit_status, 0}}
      assert gates_run(ctx) == @mutation
    end
  end

  describe "mutate.ts changed" do
    setup ctx do
      track_main(ctx.work)
      stage(ctx.work, "lib/meerkat/one.ex", "one\nrebased\n")
      no_hooks(ctx.work, ["commit", "-qm", "a rebase skips the pre-commit hook"])
      :ok
    end

    test "records HEAD once every line since origin/main passes", ctx do
      assert {out, 0} = mutate_changed(ctx)
      assert out =~ "no mutant of the changed lib/ lines survived"
      assert ["--since", "origin/main"] in Enum.chunk_every(muex_args(ctx), 2, 1)
      assert mutated?(ctx, "HEAD")
    end

    test "stops at an interrupt muex handled, records nothing, and stops its caller", ctx do
      # In its own process group, so the stub's interrupt reaches only this job.
      driver = """
      set -m
      { bun scripts/mutate.ts changed; echo "caller carried on after $1"; } &
      wait $!
      """

      path = ctx.stubs <> ":" <> System.fetch_env!("PATH")
      env = [{"PATH", path}, {"STUB_INTERRUPT", "mix muex"} | hook_env()]

      assert {out, code} =
               System.cmd("bash", ["-c", driver, "driver", "mutate.ts"],
                 cd: ctx.work,
                 env: env,
                 stderr_to_stdout: true
               )

      assert code != 0
      refute out =~ "caller carried on after mutate.ts"
      refute mutated?(ctx, "HEAD")
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
    assert mutated?(ctx, "HEAD")
  end

  defp commit(ctx, args, env \\ []) do
    path = ctx.stubs <> ":" <> System.fetch_env!("PATH")

    System.cmd("git", ["commit", "-q" | args],
      cd: ctx.work,
      env: [{"PATH", path} | hook_env()] ++ env,
      stderr_to_stdout: true
    )
  end

  # Runs `command` in the checkout, as commit/3 does, in a port that delivers
  # its output line by line and its exit status.
  defp in_port(ctx, [cmd | args]) do
    env =
      for {name, value} <- [{"PATH", ctx.stubs <> ":" <> System.fetch_env!("PATH")} | hook_env()],
          do: {String.to_charlist(name), if(value, do: String.to_charlist(value), else: false)}

    Port.open({:spawn_executable, System.find_executable(cmd)}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 4096},
      args: args,
      cd: ctx.work,
      env: env
    ])
  end

  defp await_line(port, text) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        if line =~ text, do: :ok, else: await_line(port, text)

      {^port, {:exit_status, status}} ->
        flunk("exited #{status} before printing #{inspect(text)}")
    after
      ExUnit.configuration()[:assert_receive_timeout] ->
        flunk("no line containing #{inspect(text)}")
    end
  end

  defp checked?(ctx, rev), do: recorded?(ctx, [], rev)
  defp mutated?(ctx, rev), do: recorded?(ctx, ["--mutated"], rev)
  defp e2e_checked?(ctx, rev), do: recorded?(ctx, ["--e2e"], rev)

  # `:` names the index's tree, the contents a commit would get.
  defp recorded?(ctx, store, rev) do
    tree = if rev == ":", do: git(ctx.work, ["write-tree"]), else: rev

    {_, code} =
      System.cmd("bun", ["scripts/checked-trees.ts" | store] ++ ["has", tree],
        cd: ctx.work,
        env: hook_env()
      )

    code == 0
  end

  # The fixture has no remote; origin/main stands at main's commit.
  defp track_main(work), do: git(work, ["update-ref", "refs/remotes/origin/main", "main"])

  defp mutate_changed(ctx, env \\ [], args \\ []) do
    path = ctx.stubs <> ":" <> System.fetch_env!("PATH")

    System.cmd("bun", ["scripts/mutate.ts", "changed" | args],
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
