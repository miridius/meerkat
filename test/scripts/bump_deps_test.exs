defmodule Meerkat.BumpDepsHookTest do
  # Commits through the fixture Meerkat.BumpDepsCase builds.
  use Meerkat.BumpDepsCase

  @mix_exs mix_exs()
  @hex_header hex_header()
  @hex_behind hex_behind()

  @pnpm_behind ~s({"vite": {"current": "8.2.0", "latest": "8.3.1"},
                   "shiki": {"current": "3.23.0", "latest": "4.4.3"}})

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

  # Git exports GIT_INDEX_FILE to pre-commit; a git dependency fetched
  # with it set would write to this checkout's index.
  test "the bump syncs Hex then JS dependencies first, without the index Git exports", ctx do
    stage(ctx.work, "code.txt", "change\n")

    assert {out, 0} = commit(ctx, ["-m", "change code"])
    refute out =~ "lock mismatch"

    assert Enum.take(run(ctx), 3) == [
             "mix deps.get --check-locked",
             "pnpm install --frozen-lockfile --ignore-scripts --prefer-offline",
             "mix hex.outdated"
           ]

    # check.sh's own pnpm install step logs a later line too.
    assert ctx.git_env |> File.read!() |> String.split("\n", trim: true) |> Enum.uniq() == [
             "mix deps.get --check-locked: unset",
             "pnpm install --frozen-lockfile --ignore-scripts --prefer-offline: unset"
           ]
  end

  test "a sync that would change a lockfile refuses the commit before the checks", ctx do
    File.touch!(ctx.fail_get)
    assert_refused(ctx, "mix deps.get --check-locked failed — cannot check Hex deps")

    File.rm!(ctx.fail_get)
    File.touch!(ctx.fail_install)
    assert_refused(ctx, "pnpm install --frozen-lockfile failed — cannot check JS deps")
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

  # Hex marks the cooldown only on a release the requirements admit.
  test "a release the requirements exclude is left behind while under 24h old", ctx do
    young = DateTime.utc_now() |> DateTime.add(-12, :hour) |> DateTime.to_iso8601()
    File.write!(Path.join(ctx.hex_api, "plug.json"), releases("2.1.0", young))
    File.write!(ctx.hex_out, @hex_behind)
    stage(ctx.work, "code.txt", "change\n")

    assert {_, 0} = commit(ctx, ["-m", "change code"])
    assert "mix deps.update bandit jason" in run(ctx)
    assert committed(ctx, "mix.exs") =~ ~s({:plug, "~> 1.0"})
  end

  test "an unreadable hex.pm record refuses the commit", ctx do
    File.write!(Path.join(ctx.hex_api, "plug.json"), "")
    File.write!(ctx.hex_out, @hex_behind)
    assert_refused(ctx, "could not read when hex.pm published plug 2.1.0")
  end

  test "the exclusion prune, advisory fixes and toolchain bump run after the dependency bump, and the toolchain setup before the checks",
       ctx do
    File.write!(ctx.pnpm_out, @pnpm_behind)
    File.touch!(Path.join(Path.dirname(ctx.work), "toolchain-behind"))
    File.touch!(Path.join(Path.dirname(ctx.work), "excludes-stale"))
    stage(ctx.work, "code.txt", "change\n")

    assert {_, 0} = commit(ctx, ["-m", "change code"])

    assert [
             "pnpm -r update --latest --ignore-scripts vite",
             "bun scripts/age-excludes.ts prune",
             "bun scripts/advisory-fixes.ts",
             "bun scripts/toolchain.ts bump",
             "bun scripts/setup-toolchain.ts",
             "mix compile --warnings-as-errors"
           ] ==
             Enum.filter(
               run(ctx),
               &(&1 =~
                   ~r/^(pnpm -r update --latest --ignore|bun scripts\/(age-excludes|advisory-fixes|toolchain|setup-toolchain)|mix compile)/)
             )

    assert committed(ctx, ".tool-versions") == "base\nbun 9.9.9\n"
    assert committed(ctx, ".github/actions/toolchain/action.yml") == "base\nbumped\n"
    assert committed(ctx, "pnpm-workspace.yaml") == "base\npruned\n"
  end

  for script <- ~w(age-excludes.ts advisory-fixes.ts toolchain.ts setup-toolchain.ts) do
    test "a failing #{script} refuses the commit", ctx do
      File.touch!(Path.join(Path.dirname(ctx.work), "fail-#{unquote(script)}"))
      assert_refused(ctx, "scripts/#{unquote(script)} failed")
    end
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
end
