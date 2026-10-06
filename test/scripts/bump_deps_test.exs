defmodule Meerkat.BumpDepsHookTest do
  # Commits through the repo's real lefthook.yml, scripts/bump-deps.sh,
  # scripts/deps-common.sh, scripts/bump-hex-requirements.exs and
  # scripts/check.sh. Only mix,
  # pnpm, bun and bunx are replaced, by stubs on PATH: they log each run,
  # report the outdated packages a test sets up, and record an update by
  # appending a line to the lockfile or manifest it would change.
  use Meerkat.Case, async: false

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
    fail_update = Path.join(base, "fail-update")
    npm_latest = Path.join(base, "npm-latest")
    refuse = Path.join(base, "refuse")

    File.mkdir_p!(Path.join(work, "scripts"))
    git(base, ["init", "-q", "--initial-branch=main", work])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])

    File.cp!(Path.join(@root, "lefthook.yml"), Path.join(work, "lefthook.yml"))

    for script <-
          ~w(check.sh checked-trees.sh no-main-commits.sh bump-deps.sh bump-hex-requirements.exs
             deps-common.sh) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([work, "scripts", script]))
    end

    # Fixed rather than copied, so a new upstream release cannot change it.
    File.write!(
      Path.join([work, "scripts", "dep-exemptions.json"]),
      ~s({"shiki": {"version": "4.4.3", "reason": "upstream needs shiki 3"}})
    )

    # This test covers the dependency bump, not the runner; keep the fixture's
    # runner as `exec mix test` so check.sh's test step is logged as `mix test`.
    File.write!(Path.join([work, "scripts", "mix-test.sh"]), "exec mix test\n")

    File.write!(Path.join(work, ".gitignore"), "node_modules\n")
    File.write!(Path.join(work, "mix.exs"), @mix_exs)

    for file <-
          ~w(mix.lock package.json pnpm-workspace.yaml pnpm-lock.yaml assets/package.json code.txt) do
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
    File.mkdir_p!(npm_latest)
    File.mkdir_p!(refuse)

    File.write!(Path.join(stubs, "stub"), """
    #!/usr/bin/env bash
    cmd="$(basename "$0") $*"
    echo "$cmd" >> '#{log}'
    case "$cmd" in
      "mix hex.outdated") cat '#{hex_out}'; exit 1 ;;
      "mix deps.update "*)
        [[ -e '#{fail_update}' ]] && exit 1
        echo "updated ${cmd#mix deps.update }" >> mix.lock ;;
      "pnpm -r outdated --format json")
        echo " WARN  deprecated subdependency" >&2
        cat '#{pnpm_out}'; exit 1 ;;
      "pnpm view "*" dist-tags.latest")
        if [[ -e '#{npm_latest}'/"$2" ]]; then cat '#{npm_latest}'/"$2"
        else jq -r --arg n "$2" '.[$n].latest' '#{pnpm_out}'; fi ;;
      "pnpm -r update --latest --lockfile-only --ignore-scripts "*)
        # Only a scratch copy of the workspace, without the repo's scripts/.
        [[ ! -e scripts && -f package.json && -f pnpm-workspace.yaml && -f pnpm-lock.yaml &&
           -f assets/package.json && -L deps ]] || { echo "not a scratch workspace copy"; exit 1; }
        echo "updated $6" | tee -a package.json >> pnpm-lock.yaml
        if [[ -e '#{refuse}'/"$6" ]]; then cat '#{refuse}'/"$6"; exit 1; fi ;;
      "pnpm -r update --latest --ignore-scripts "*)
        names="${cmd#pnpm -r update --latest --ignore-scripts }"
        echo "updated $names" >> package.json
        echo "updated $names" >> assets/package.json
        echo "updated $names" >> pnpm-lock.yaml ;;
      "mix compile --warnings-as-errors") cp mix.lock '#{seen}' ;;
    esac
    """)

    File.chmod!(Path.join(stubs, "stub"), 0o755)
    for tool <- ~w(mix pnpm bun bunx), do: File.ln_s!("stub", Path.join(stubs, tool))

    {:ok,
     work: work,
     stubs: stubs,
     log: log,
     hex_out: hex_out,
     pnpm_out: pnpm_out,
     seen: seen,
     fail_update: fail_update,
     npm_latest: npm_latest,
     refuse: refuse}
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
    assert committed(ctx, "package.json") == "base\nupdated vite\n"
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

  test "an exemption for an older release does not hold back a newer one", ctx do
    File.write!(
      Path.join(ctx.work, "scripts/dep-exemptions.json"),
      ~s({"shiki": {"version": "4.4.2", "reason": "upstream needs shiki 3"}})
    )

    File.write!(ctx.pnpm_out, @pnpm_behind)
    stage(ctx.work, "code.txt", "change\n")

    assert {_, 0} = commit(ctx, ["-m", "change code"])
    assert "pnpm -r update --latest --ignore-scripts vite shiki" in run(ctx)
  end

  test "a commit while everything is current changes no dependency file", ctx do
    stage(ctx.work, "code.txt", "change\n")

    assert {_, 0} = commit(ctx, ["-m", "change code"])
    assert changed_files(ctx) == ["code.txt"]
    refute Enum.any?(run(ctx), &(&1 =~ ~r/deps\.update|pnpm -r update/))
  end

  test "an unreadable Hex report refuses the commit before the checks", ctx do
    for report <- ["** (Mix) boom\n", @hex_header <> "** (Mix) Could not fetch registry\n"] do
      File.write!(ctx.hex_out, report)
      assert_refused(ctx, "cannot check Hex deps")
    end
  end

  test "an unreadable pnpm report refuses the commit before the checks", ctx do
    for report <- ["", "[]", ~s("oops"), "null", ~s({"vite": {"current": "8.2.0"}})] do
      File.write!(ctx.pnpm_out, report)
      assert_refused(ctx, "cannot check JS deps")
    end
  end

  test "a malformed exemption table refuses the commit", ctx do
    for table <- [~s({"shiki": {"reason": "x"}}), "[]", ""] do
      File.write!(Path.join(ctx.work, "scripts/dep-exemptions.json"), table)
      File.write!(ctx.pnpm_out, @pnpm_behind)
      assert_refused(ctx, ~s(each entry needs a "version" and a "reason"))
    end
  end

  test "a failed update refuses the commit and restores mix.exs", ctx do
    File.write!(ctx.hex_out, @hex_behind)
    File.touch!(ctx.fail_update)
    assert_refused(ctx, "mix deps.update bandit jason plug failed, so the commit was refused")
    assert File.read!(Path.join(ctx.work, "mix.exs")) == @mix_exs
  end

  # pnpm outdated reports the newest release past minimumReleaseAge as
  # latest, so a release under 24h shows only in the registry's latest.
  describe "an entry while a JS release is under 24h" do
    setup ctx do
      File.write!(ctx.pnpm_out, ~s({"shiki": {"current": "3.23.0", "latest": "4.4.2"}}))
      File.write!(Path.join(ctx.npm_latest, "shiki"), "4.4.3\n")
      stage(ctx.work, "code.txt", "change\n")
      :ok
    end

    for {version, case_name} <- [
          {"4.4.2", "the release pnpm reports"},
          {"4.4.3", "the young one"}
        ] do
      test "naming #{case_name} leaves the package alone", ctx do
        File.write!(
          Path.join(ctx.work, "scripts/dep-exemptions.json"),
          ~s({"shiki": {"version": "#{unquote(version)}", "reason": "x"}})
        )

        assert {_, 0} = commit(ctx, ["-m", "change code"])
        refute Enum.any?(run(ctx), &(&1 =~ "pnpm -r update"))
      end
    end

    test "naming an older release does not hold it back", ctx do
      File.write!(
        Path.join(ctx.work, "scripts/dep-exemptions.json"),
        ~s({"shiki": {"version": "4.4.1", "reason": "x"}})
      )

      assert {_, 0} = commit(ctx, ["-m", "change code"])
      assert "pnpm -r update --latest --ignore-scripts shiki" in run(ctx)
    end
  end

  test "a JS release pnpm refuses for a younger version it requires is left behind", ctx do
    File.write!(ctx.pnpm_out, ~s({"vite": {"current": "8.2.0", "latest": "8.3.1"},
                                  "lefthook": {"current": "2.1.16", "latest": "2.1.17"}}))

    File.write!(
      Path.join(ctx.refuse, "lefthook"),
      " ERR_PNPM_NO_MATURE_MATCHING_VERSION  Version 2.1.17 (released 24 hours ago) of lefthook-windows-x64 does not meet the minimumReleaseAge constraint\n"
    )

    stage(ctx.work, "code.txt", "change\n")

    assert {out, 0} = commit(ctx, ["-m", "change code"])
    assert out =~ "ERR_PNPM_NO_MATURE_MATCHING_VERSION  Version 2.1.17"
    assert out =~ "lefthook@2.1.17 requires a package version under the 24h floor; not bumped yet"
    assert "pnpm -r update --latest --ignore-scripts vite" in run(ctx)
    # The installability checks ran on scratch copies, not the tree.
    assert committed(ctx, "package.json") == "base\nupdated vite\n"
    assert committed(ctx, "pnpm-lock.yaml") == "base\nupdated vite\n"
    assert git(ctx.work, ["status", "--porcelain"]) == ""
  end

  test "a JS release pnpm cannot resolve for another reason refuses the commit", ctx do
    File.write!(ctx.pnpm_out, @pnpm_behind)
    File.write!(Path.join(ctx.refuse, "vite"), " ERR_PNPM_META_FETCH_FAIL  GET failed\n")
    assert_refused(ctx, "pnpm could not resolve vite's latest release (exit 1)")
  end

  test "an exempt Hex release is left behind", ctx do
    File.write!(
      Path.join(ctx.work, "scripts/dep-exemptions.json"),
      ~s({"plug": {"version": "2.1.0", "reason": "x"}, "jason": {"version": "1.4.5", "reason": "x"}})
    )

    File.write!(ctx.hex_out, @hex_behind)
    stage(ctx.work, "code.txt", "change\n")

    assert {_, 0} = commit(ctx, ["-m", "change code"])
    assert "mix deps.update bandit" in run(ctx)
    assert committed(ctx, "mix.exs") =~ ~s({:plug, "~> 1.0"})
  end

  test "a release another dependency holds back leaves mix.exs alone", ctx do
    File.write!(ctx.hex_out, @hex_header <> "jason  1.4.3  1.4.5  Update not possible\n")
    stage(ctx.work, "code.txt", "change\n")

    assert {out, 0} = commit(ctx, ["-m", "change code"])
    assert out =~ ~s(jason "~> 1.2" allows 1.4.5; another dependency holds it back)
    assert committed(ctx, "mix.exs") == @mix_exs
  end

  test "a requirement the hook cannot move refuses the commit, naming it", ctx do
    File.write!(Path.join(ctx.work, "mix.exs"), String.replace(@mix_exs, "~> 1.0", "== 1.0.0"))
    git(ctx.work, ["add", "mix.exs"])
    File.write!(ctx.hex_out, @hex_header <> "plug  1.0.0  2.1.0  Update not possible\n")

    assert_refused(ctx, ~s(mix.exs plug "== 1.0.0" excludes 2.1.0))
  end

  test "Hex rows with an Only column or in cooldown parse by their Status", ctx do
    File.write!(ctx.hex_out, """
    #{@hex_header}credo  dev,test  1.7.18  1.7.19  Update possible
    jason  1.4.3  1.4.5  Update possible (cooldown)
    plug  test  1.20.3  2.1.0  Update not possible

    Run `mix hex.outdated APP` to see requirements for a specific dependency.
    """)

    stage(ctx.work, "code.txt", "change\n")

    assert {_, 0} = commit(ctx, ["-m", "change code"])
    assert "mix deps.update credo plug" in run(ctx)
    assert committed(ctx, "mix.exs") =~ ~s({:plug, "~> 2.1"})
  end

  test "a path commit defers the bump and leaves the index matching HEAD", ctx do
    File.write!(ctx.pnpm_out, @pnpm_behind)
    File.write!(Path.join(ctx.work, "code.txt"), "path\n")

    assert {out, 0} = commit(ctx, ["-m", "change code", "code.txt"])
    assert out =~ "dependency bump deferred to the next full commit"
    assert changed_files(ctx) == ["code.txt"]
    refute Enum.any?(run(ctx), &(&1 =~ "pnpm -r update"))
    assert git(ctx.work, ["status", "--porcelain"]) == ""
  end

  test "an unstaged edit to a dependency file the bump left alone stays unstaged", ctx do
    File.write!(ctx.pnpm_out, ~s({"vite": {"current": "8.2.0", "latest": "8.3.1"}}))
    File.write!(Path.join(ctx.work, "mix.lock"), "base\nwork in progress\n")
    stage(ctx.work, "code.txt", "change\n")

    assert {_, 0} = commit(ctx, ["-m", "change code"])
    assert committed(ctx, "mix.lock") == "base\n"
    assert "pnpm-lock.yaml" in changed_files(ctx)
    assert git(ctx.work, ["status", "--porcelain"]) == "M mix.lock"
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

  # The commit fails with `message`, and no check ran.
  defp assert_refused(ctx, message) do
    stage(ctx.work, "code.txt", "change #{System.unique_integer()}\n")
    head = git(ctx.work, ["rev-parse", "HEAD"])
    File.rm(ctx.log)

    assert {out, code} = commit(ctx, ["-m", "change code"])
    assert code != 0
    assert out =~ message
    assert git(ctx.work, ["rev-parse", "HEAD"]) == head
    refute Enum.any?(run(ctx), &(&1 =~ "mix compile"))
  end

  defp committed(ctx, file), do: git(ctx.work, ["show", "HEAD:#{file}"]) <> "\n"

  defp changed_files(ctx) do
    ctx.work
    |> git(["diff", "--name-only", "HEAD~1", "HEAD", "--" | @dep_files ++ ["code.txt"]])
    |> String.split("\n", trim: true)
  end

  defp run(ctx) do
    case File.read(ctx.log) do
      {:ok, log} -> String.split(log, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp no_hooks(work, args), do: git(work, ["-c", "core.hooksPath=/dev/null" | args])
end
