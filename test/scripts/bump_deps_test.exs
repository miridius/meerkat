defmodule Meerkat.BumpDepsHookTest do
  # The seams between Git, the repo's real lefthook.yml and
  # scripts/bump-deps.ts and scripts/rebase-bump.ts: commits and a rebase
  # through hooks that run the real scripts, with mix, pnpm, bun and curl
  # replaced by stubs on PATH, and check.ts and mutate.ts by stubs in the
  # fixture. The stubs log each run, report the outdated packages a test
  # sets up, and record an update by appending a line to the file it would
  # change. scripts/bump-deps.test.ts and scripts/rebase-bump.test.ts cover
  # the scripts' logic.
  use Meerkat.Case, async: true

  import Meerkat.TestHelpers, only: [git: 2, hook_env: 0, stage: 3]

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

  @hex_behind """
  Dependency  Only  Current  Latest  Status
  bandit            1.11.0   1.12.5  Update not possible
  jason             1.4.3    1.4.5   Update possible
  plug              1.20.3   2.1.0   Update not possible
  mdex              0.14.1   0.14.1  Up-to-date
  """

  @pnpm_behind ~s({"vite": {"current": "8.2.0", "latest": "8.3.1"},
                   "shiki": {"current": "3.23.0", "latest": "4.4.3"}})

  @dep_files ~w(mix.exs mix.lock package.json pnpm-lock.yaml assets/package.json)

  # Built once, then copied for each test.
  setup_all do
    {:ok,
     template:
       Meerkat.TestHelpers.fixture_template("meerkat-bump-deps-template", &build_fixture/1)}
  end

  setup %{template: template} do
    base = Meerkat.TestHelpers.copy_fixture(template, "meerkat-bump-deps")
    {:ok, base: base, work: Path.join(base, "work"), stubs: Path.join(base, "stubs")}
  end

  test "a commit while dependencies are behind carries their bump, checked", ctx do
    File.write!(Path.join(ctx.base, "hex.out"), @hex_behind)
    File.write!(Path.join(ctx.base, "pnpm.json"), @pnpm_behind)
    File.touch!(Path.join(ctx.base, "toolchain-behind"))
    stage(ctx.work, "code.txt", "change\n")
    head = git(ctx.work, ["rev-parse", "HEAD"])

    # A failed update refuses the commit, restoring mix.exs.
    File.touch!(Path.join(ctx.base, "fail-update"))
    assert {out, code} = commit(ctx, ["-m", "change code"])
    assert code != 0
    assert out =~ "mix deps.update bandit jason plug failed, so the commit was refused"
    assert git(ctx.work, ["rev-parse", "HEAD"]) == head
    assert File.read!(Path.join(ctx.work, "mix.exs")) == @mix_exs
    refute File.exists?(Path.join(ctx.base, "seen"))

    File.rm!(Path.join(ctx.base, "fail-update"))
    assert {out, 0} = commit(ctx, ["-m", "change code"])
    assert out =~ "staged the dependency bump"

    assert committed(ctx, "mix.exs") =~ ~s({:bandit, "~> 1.12.5"})
    assert committed(ctx, "mix.exs") =~ ~s({:jason, "~> 1.2"})
    assert committed(ctx, "mix.exs") =~ ~s({:plug, "~> 2.1"})
    assert committed(ctx, "mix.lock") == "base\nupdated bandit jason plug\n"
    # The exempt shiki is left behind.
    assert committed(ctx, "package.json") == "base\nupdated vite\n"
    assert committed(ctx, "assets/package.json") == "base\nupdated vite\n"
    assert committed(ctx, "pnpm-lock.yaml") == "base\nupdated vite\n"
    assert committed(ctx, ".tool-versions") == "base\nbun 9.9.9\n"
    assert git(ctx.work, ["status", "--porcelain"]) == ""

    # The checks ran after the bump, against the bumped snapshot.
    assert File.read!(Path.join(ctx.base, "seen")) == "base\nupdated bandit jason plug\n"

    # Git exports GIT_INDEX_FILE to pre-commit; a git dependency fetched
    # with it set would write to this checkout's index.
    assert ctx.base |> Path.join("git-env") |> File.read!() |> String.split("\n", trim: true) ==
             List.duplicate(
               [
                 "mix deps.get --check-locked: unset",
                 "pnpm install --frozen-lockfile --ignore-scripts --prefer-offline: unset"
               ],
               2
             )
             |> List.flatten()
  end

  test "a path commit defers the bump, and `git commit -a` carries it", ctx do
    File.write!(Path.join(ctx.base, "pnpm.json"), @pnpm_behind)

    File.write!(Path.join(ctx.work, "code.txt"), "path\n")
    assert {out, 0} = commit(ctx, ["-m", "path commit", "code.txt"])
    assert out =~ "dependency bump deferred to the next full commit"
    assert changed_files(ctx) == ["code.txt"]
    assert git(ctx.work, ["status", "--porcelain"]) == ""

    File.write!(Path.join(ctx.work, "code.txt"), "all\n")
    assert {_, 0} = commit(ctx, ["-am", "all commit"])
    assert "pnpm-lock.yaml" in changed_files(ctx)
    assert git(ctx.work, ["status", "--porcelain"]) == ""
  end

  # A rebase makes its commits without the pre-commit hook, so a release
  # that came out since they were made is bumped by post-rewrite.
  test "a rebase while dependencies are behind commits their bump on top, checked", ctx do
    no_hooks(ctx.work, ["switch", "-q", "main"])
    stage(ctx.work, "main.txt", "main\n")
    no_hooks(ctx.work, ["commit", "-qm", "main moves"])
    no_hooks(ctx.work, ["switch", "-q", "feature"])
    stage(ctx.work, "code.txt", "feature\n")
    no_hooks(ctx.work, ["commit", "-qm", "feature work"])
    File.write!(Path.join(ctx.base, "hex.out"), @hex_behind)

    assert {out, 0} = hooked(ctx, ["rebase", "main"])
    assert out =~ "post-rewrite: committed the dependency bump on top of the rebase"

    assert ctx.work |> git(["log", "--format=%s"]) |> String.split("\n") ==
             ["Bump dependencies", "feature work", "main moves", "base"]

    assert changed_files(ctx) == ["mix.exs", "mix.lock"]
    assert committed(ctx, "mix.exs") =~ ~s({:bandit, "~> 1.12.5"})
    assert git(ctx.work, ["branch", "--show-current"]) == "feature"
    assert git(ctx.work, ["status", "--porcelain"]) == ""
    # The pre-commit checks ran on the bump commit, after its own bump ran
    # again there, so they saw the committed mix.lock.
    assert File.read!(Path.join(ctx.base, "seen")) == committed(ctx, "mix.lock")
  end

  defp build_fixture(base) do
    work = Path.join(base, "work")
    stubs = Path.join(base, "stubs")
    log = Path.join(base, "log")
    # Read at run time, not compile time: a compiled module copied from
    # another checkout's _build would otherwise copy that checkout's scripts.
    root = File.cwd!()
    bun = System.find_executable("bun")

    File.mkdir_p!(Path.join(work, "scripts"))
    git(base, ["init", "-q", "--initial-branch=main", work])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])

    File.cp!(Path.join(root, "lefthook.yml"), Path.join(work, "lefthook.yml"))

    for script <-
          ~w(no-main-commits.ts checked-trees.ts bump-deps.ts deps-common.ts bump-hex-requirements.exs rebase-bump.ts) do
      File.cp!(Path.join([root, "scripts", script]), Path.join([work, "scripts", script]))
    end

    # Fixed rather than copied, so a new upstream release cannot change it.
    File.write!(
      Path.join([work, "scripts", "dep-exemptions.json"]),
      ~s({"shiki": {"version": "4.4.3", "reason": "upstream needs shiki 3"}})
    )

    # test/scripts/pre_commit_test.exs covers the checks and the mutation
    # gate. This check records the mix.lock it was given to check, by a
    # relative path: copy_fixture would rewrite a tracked file naming base.
    File.write!(Path.join([work, "scripts", "check.ts"]), """
    import { writeFileSync } from "node:fs";
    writeFileSync("../seen", Bun.spawnSync(["git", "show", ":mix.lock"]).stdout);
    """)

    File.write!(Path.join([work, "scripts", "mutate.ts"]), "")

    File.write!(Path.join(work, ".gitignore"), "node_modules\n")
    File.write!(Path.join(work, "mix.exs"), @mix_exs)

    for file <-
          ~w(mix.lock package.json pnpm-workspace.yaml pnpm-lock.yaml assets/package.json code.txt
             .tool-versions) do
      File.mkdir_p!(Path.dirname(Path.join(work, file)))
      File.write!(Path.join(work, file), "base\n")
    end

    git(work, ["add", "-A"])
    no_hooks(work, ["commit", "-qm", "base"])
    no_hooks(work, ["switch", "-q", "-c", "feature"])

    Meerkat.TestHelpers.install_lefthook(work)

    File.write!(Path.join(base, "hex.out"), "Dependency  Only  Current  Latest  Status\n")
    File.write!(Path.join(base, "pnpm.json"), "{}")
    File.mkdir_p!(stubs)

    # hex.pm's record of each release the requirements exclude, published
    # long ago.
    for {name, version} <- [{"bandit", "1.12.5"}, {"plug", "2.1.0"}] do
      File.write!(
        Path.join(base, name <> ".json"),
        Jason.encode!(%{
          "releases" => [%{"version" => version, "inserted_at" => "2020-01-01T00:00:00Z"}]
        })
      )
    end

    File.write!(Path.join(stubs, "stub"), """
    #!/usr/bin/env bash
    cmd="$(basename "$0") $*"
    case "$cmd" in
      "bun scripts/bump-deps.ts" | "bun scripts/rebase-bump.ts "* | "bun scripts/check.ts" | "bun scripts/mutate.ts staged" | "bun scripts/no-main-commits.ts") exec '#{bun}' "$@" ;;
    esac
    echo "$cmd" >> '#{log}'
    case "$cmd" in
      "mix deps.get --check-locked" | "pnpm install --frozen-lockfile "*)
        echo "$cmd: ${GIT_INDEX_FILE-unset}" >> '#{base}/git-env' ;;
      "mix hex.outdated") cat '#{base}/hex.out'; exit 1 ;;
      "curl "*/api/packages/*) cat '#{base}'/"${cmd##*/}.json" ;;
      "mix deps.update "*)
        [[ -e '#{base}/fail-update' ]] && exit 1
        echo "updated ${cmd#mix deps.update }" >> mix.lock ;;
      "pnpm -r outdated --format json") cat '#{base}/pnpm.json'; exit 1 ;;
      "pnpm -r update --latest --ignore-scripts "*)
        names="${cmd#pnpm -r update --latest --ignore-scripts }"
        for file in package.json assets/package.json pnpm-lock.yaml; do
          echo "updated $names" >> "$file"
        done ;;
      "bun scripts/toolchain.ts bump")
        if [[ -e '#{base}/toolchain-behind' ]]; then echo "bun 9.9.9" >> .tool-versions; fi ;;
    esac
    """)

    File.chmod!(Path.join(stubs, "stub"), 0o755)
    for tool <- ~w(mix pnpm bun curl), do: File.ln_s!("stub", Path.join(stubs, tool))
  end

  defp commit(ctx, args), do: hooked(ctx, ["commit", "-q" | args])

  # Runs git with the repo's hooks and the stubs on PATH.
  defp hooked(ctx, args) do
    System.cmd("git", args,
      cd: ctx.work,
      env: [{"PATH", ctx.stubs <> ":" <> System.fetch_env!("PATH")} | hook_env()],
      stderr_to_stdout: true
    )
  end

  defp committed(ctx, file), do: git(ctx.work, ["show", "HEAD:#{file}"]) <> "\n"

  defp changed_files(ctx) do
    ctx.work
    |> git(["diff", "--name-only", "HEAD~1", "HEAD", "--" | @dep_files ++ ["code.txt"]])
    |> String.split("\n", trim: true)
  end

  defp no_hooks(work, args), do: git(work, ["-c", "core.hooksPath=/dev/null" | args])
end
