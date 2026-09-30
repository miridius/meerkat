defmodule Meerkat.PreCommitHookTest do
  # Commits through the repo's real lefthook.yml, scripts/no-main-commits.sh
  # and scripts/check.sh. Only the tools check.sh runs (mix, pnpm, bun,
  # bunx) are replaced, by stubs on PATH that log each run and can fail it.
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
    "mix test",
    "bun test",
    "bun run build",
    "bunx playwright install --only-shell chromium",
    "bun run test:e2e"
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

    File.mkdir_p!(Path.join(work, "scripts"))
    git(base, ["init", "-q", "--initial-branch=main", work])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])

    File.cp!(Path.join(@root, "lefthook.yml"), Path.join(work, "lefthook.yml"))

    for script <- ~w(check.sh no-main-commits.sh) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([work, "scripts", script]))
    end

    File.write!(Path.join(work, ".gitignore"), "node_modules\n")
    File.mkdir_p!(Path.join(work, "assets"))
    File.write!(Path.join(work, "assets/.keep"), "")
    File.write!(Path.join(work, "code.txt"), "base\n")
    git(work, ["add", "-A"])
    no_hooks(work, ["commit", "-qm", "base"])
    no_hooks(work, ["switch", "-q", "-c", "feature"])

    Meerkat.TestHelpers.install_lefthook(work)

    # The compile stub records where it runs and which git variables leak
    # into it.
    File.mkdir_p!(stubs)

    File.write!(Path.join(stubs, "stub"), """
    #!/usr/bin/env bash
    cmd="$(basename "$0") $*"
    echo "$cmd" >> '#{log}'
    if [ "$cmd" = "mix compile --warnings-as-errors" ]; then
      {
        echo "pwd=$PWD"
        env | grep '^GIT_' | sed 's/^/env=/'
      } > '#{seen}'
    fi
    [ "$cmd" != "${STUB_FAIL:-}" ]
    """)

    File.chmod!(Path.join(stubs, "stub"), 0o755)
    for tool <- ~w(mix pnpm bun bunx), do: File.ln_s!("stub", Path.join(stubs, tool))

    {:ok, work: work, stubs: stubs, log: log, seen: seen}
  end

  test "a commit runs every gate in the checkout", ctx do
    stage(ctx.work, "code.txt", "staged\n")

    assert {out, 0} = commit(ctx, ["-m", "change code"])
    assert out =~ "all checks passed"
    assert gates_run(ctx) == @gates

    seen = seen(ctx)
    assert "pwd=#{git(ctx.work, ["rev-parse", "--show-toplevel"])}" in seen

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

  test "a commit on main is refused before any check runs", ctx do
    no_hooks(ctx.work, ["switch", "-q", "main"])
    stage(ctx.work, "code.txt", "staged\n")

    assert {_, code} = commit(ctx, ["-m", "on main"])
    assert code != 0
    assert gates_run(ctx) == []
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

  # Only commits go through the hooks; other commands would fire lefthook's
  # post-checkout install, whose script this fixture leaves out.
  defp no_hooks(work, args), do: git(work, ["-c", "core.hooksPath=/dev/null" | args])
end
