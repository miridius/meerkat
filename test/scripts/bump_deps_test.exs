defmodule Meerkat.BumpDepsHookTest do
  # Commits through the repo's real lefthook.yml, scripts/bump-deps.sh,
  # scripts/bump-hex-requirements.exs and scripts/check.sh. Only mix,
  # pnpm, bun and bunx are replaced, by stubs on PATH: they log each run,
  # report the outdated packages a test sets up, and record an update by
  # appending a line to the lockfile or manifest it would change.
  use ExUnit.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, stage: 3, hook_env: 0]

  @root File.cwd!()

  @mix_exs """
  defmodule Fixture.MixProject do
    use Mix.Project

    defp deps do
      [
        {:bandit, "~> 1.11.0"},
        {:jason, "~> 1.2"},
        {:plug, "~> 1.0"}
      ]
    end
  end
  """

  @hex_header "Dependency  Only  Current  Latest  Status\n"

  @hex_behind @hex_header <>
                """
                bandit            1.11.0   1.12.5  Update not possible
                jason             1.4.3    1.4.5   Update possible
                plug              1.20.3   2.1.0   Update not possible
                mdex              0.14.1   0.14.1  Up-to-date
                """

  @pnpm_behind ~s({"vite": {"current": "8.2.0", "latest": "8.3.1"},
                   "shiki": {"current": "3.23.0", "latest": "4.4.3"}})

  @dep_files ~w(mix.exs mix.lock package.json pnpm-lock.yaml assets/package.json)

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-bump-deps")
    on_exit(fn -> File.rm_rf!(base) end)
    File.rm_rf!(Path.join(base, ".git"))

    work = Path.join(base, "work")
    stubs = Path.join(base, "stubs")
    log = Path.join(base, "log")
    hex_out = Path.join(base, "hex.out")
    pnpm_out = Path.join(base, "pnpm.json")
    seen = Path.join(base, "seen")

    File.mkdir_p!(Path.join(work, "scripts"))
    git(base, ["init", "-q", "--initial-branch=main", work])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])

    File.cp!(Path.join(@root, "lefthook.yml"), Path.join(work, "lefthook.yml"))

    for script <-
          ~w(check.sh no-main-commits.sh bump-deps.sh bump-hex-requirements.exs dep-exemptions.json) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([work, "scripts", script]))
    end

    File.write!(Path.join(work, ".gitignore"), "node_modules\n")
    File.write!(Path.join(work, "mix.exs"), @mix_exs)

    for file <- ~w(mix.lock package.json pnpm-lock.yaml assets/package.json code.txt) do
      File.mkdir_p!(Path.dirname(Path.join(work, file)))
      File.write!(Path.join(work, file), "base\n")
    end

    git(work, ["add", "-A"])
    no_hooks(work, ["commit", "-qm", "base"])
    no_hooks(work, ["switch", "-q", "-c", "feature"])

    Meerkat.TestHelpers.install_lefthook(work)

    File.write!(hex_out, @hex_header <> "mdex  0.14.1  0.14.1  Up-to-date\n")
    File.write!(pnpm_out, "{}")

    File.mkdir_p!(stubs)

    File.write!(Path.join(stubs, "stub"), """
    #!/usr/bin/env bash
    cmd="$(basename "$0") $*"
    echo "$cmd" >> '#{log}'
    case "$cmd" in
      "mix hex.outdated") cat '#{hex_out}'; exit 1 ;;
      "mix deps.update "*) echo "updated ${cmd#mix deps.update }" >> mix.lock ;;
      "pnpm -r outdated --format json") cat '#{pnpm_out}'; exit 1 ;;
      "pnpm -r update --latest --ignore-scripts "*)
        names="${cmd#pnpm -r update --latest --ignore-scripts }"
        echo "updated $names" >> assets/package.json
        echo "updated $names" >> pnpm-lock.yaml ;;
      "mix compile --warnings-as-errors") cp mix.lock '#{seen}' ;;
    esac
    """)

    File.chmod!(Path.join(stubs, "stub"), 0o755)
    for tool <- ~w(mix pnpm bun bunx), do: File.ln_s!("stub", Path.join(stubs, tool))

    {:ok, work: work, stubs: stubs, log: log, hex_out: hex_out, pnpm_out: pnpm_out, seen: seen}
  end

  test "a commit while dependencies are behind carries their bump", ctx do
    File.write!(ctx.hex_out, @hex_behind)
    File.write!(ctx.pnpm_out, @pnpm_behind)
    stage(ctx.work, "code.txt", "change\n")

    assert {out, 0} = commit(ctx, ["-m", "change code"])
    assert out =~ "staged the dependency bump"

    assert committed(ctx, "mix.exs") =~ ~s({:bandit, "~> 1.12.5"})
    assert committed(ctx, "mix.exs") =~ ~s({:jason, "~> 1.2"})
    assert committed(ctx, "mix.exs") =~ ~s({:plug, "~> 2.1"})
    assert committed(ctx, "mix.lock") == "base\nupdated bandit jason plug\n"
    assert committed(ctx, "assets/package.json") == "base\nupdated vite\n"
    assert committed(ctx, "pnpm-lock.yaml") == "base\nupdated vite\n"
    assert git(ctx.work, ["status", "--porcelain"]) == ""

    # The checks ran after the bump, against the bumped snapshot.
    assert File.read!(ctx.seen) == "base\nupdated bandit jason plug\n"
  end

  test "an exempt package is left behind", ctx do
    File.write!(ctx.pnpm_out, @pnpm_behind)
    stage(ctx.work, "code.txt", "change\n")

    assert {_, 0} = commit(ctx, ["-m", "change code"])
    assert "pnpm -r update --latest --ignore-scripts vite" in run(ctx)
    refute Enum.any?(run(ctx), &(&1 =~ "shiki"))
  end

  test "a commit while everything is current changes no dependency file", ctx do
    stage(ctx.work, "code.txt", "change\n")

    assert {_, 0} = commit(ctx, ["-m", "change code"])
    assert changed_files(ctx) == ["code.txt"]
    refute Enum.any?(run(ctx), &(&1 =~ ~r/deps\.update|pnpm -r update/))
  end

  test "unstaged edits to a dependency file skip the bump and stay out of the commit", ctx do
    File.write!(ctx.hex_out, @hex_behind)
    stage(ctx.work, "code.txt", "change\n")
    File.write!(Path.join(ctx.work, "mix.lock"), "base\nmine\n")

    assert {out, 0} = commit(ctx, ["-m", "change code"])
    assert out =~ "unstaged changes; skipping the dependency bump"
    assert changed_files(ctx) == ["code.txt"]
    assert File.read!(Path.join(ctx.work, "mix.lock")) == "base\nmine\n"
  end

  test "an unreadable outdated report refuses the commit", ctx do
    File.write!(ctx.hex_out, "** (Mix) boom\n")
    stage(ctx.work, "code.txt", "change\n")
    head = git(ctx.work, ["rev-parse", "HEAD"])

    assert {out, code} = commit(ctx, ["-m", "change code"])
    assert code != 0
    assert out =~ "cannot bump Hex deps"
    assert git(ctx.work, ["rev-parse", "HEAD"]) == head
  end

  test "`git commit -a` carries the bump too", ctx do
    File.write!(ctx.pnpm_out, @pnpm_behind)
    File.write!(Path.join(ctx.work, "code.txt"), "all\n")

    assert {_, 0} = commit(ctx, ["-am", "change code"])
    assert "pnpm-lock.yaml" in changed_files(ctx)
    assert git(ctx.work, ["status", "--porcelain"]) == ""
  end

  defp commit(ctx, args) do
    path = ctx.stubs <> ":" <> System.fetch_env!("PATH")

    System.cmd("git", ["commit", "-q" | args],
      cd: ctx.work,
      env: [{"PATH", path} | hook_env()],
      stderr_to_stdout: true
    )
  end

  defp committed(ctx, file), do: git(ctx.work, ["show", "HEAD:#{file}"]) <> "\n"

  defp changed_files(ctx) do
    ctx.work
    |> git(["diff", "--name-only", "HEAD~1", "HEAD", "--" | @dep_files ++ ["code.txt"]])
    |> String.split("\n", trim: true)
  end

  defp run(ctx), do: ctx.log |> File.read!() |> String.split("\n", trim: true)

  defp no_hooks(work, args), do: git(work, ["-c", "core.hooksPath=/dev/null" | args])
end
