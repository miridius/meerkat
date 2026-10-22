defmodule Meerkat.RebaseBumpHookTest do
  # A rebase makes its commits without the pre-commit hook, so a release
  # that came out since they were made is bumped by post-rewrite. Rebases
  # and amends through the fixture Meerkat.BumpDepsCase builds.
  use Meerkat.BumpDepsCase

  @hex_behind hex_behind()

  describe "a rebase" do
    setup ctx do
      no_hooks(ctx.work, ["switch", "-q", "main"])
      stage(ctx.work, "main.txt", "main\n")
      no_hooks(ctx.work, ["commit", "-qm", "main moves"])
      no_hooks(ctx.work, ["switch", "-q", "feature"])
      stage(ctx.work, "code.txt", "feature\n")
      no_hooks(ctx.work, ["commit", "-qm", "feature work"])
      :ok
    end

    test "while dependencies are behind commits their bump on top, checked", ctx do
      File.write!(ctx.hex_out, @hex_behind)

      assert {out, 0} = hooked(ctx, ["rebase", "main"])
      assert out =~ "committed the dependency bump on top of the rebase"

      assert subjects(ctx) == ["Bump dependencies", "feature work", "main moves", "base"]
      assert changed_files(ctx) == ["mix.exs", "mix.lock"]
      assert committed(ctx, "mix.exs") =~ ~s({:bandit, "~> 1.12.5"})
      assert git(ctx.work, ["branch", "--show-current"]) == "feature"
      assert git(ctx.work, ["status", "--porcelain"]) == ""
      # The pre-commit checks ran on the bump commit, after its own bump ran
      # again there, so they saw the committed mix.lock.
      assert File.read!(ctx.seen) == committed(ctx, "mix.lock")
    end

    test "while everything is current adds no commit", ctx do
      assert {out, 0} = hooked(ctx, ["rebase", "main"])
      refute out =~ "post-rewrite:"
      assert subjects(ctx) == ["feature work", "main moves", "base"]
      assert "mix hex.outdated" in run(ctx)
    end

    test "whose bump fails is left done, saying so", ctx do
      File.write!(ctx.hex_out, @hex_behind)
      File.touch!(ctx.fail_update)

      assert {out, 0} = hooked(ctx, ["rebase", "main"])

      assert out =~
               "scripts/bump-deps.sh failed, so the rebase was left without a dependency bump commit"

      refute out =~ "left in the worktree"
      assert subjects(ctx) == ["feature work", "main moves", "base"]
      assert git(ctx.work, ["status", "--porcelain"]) == ""
    end

    test "whose bump commit the checks refuse leaves the bump staged, saying so", ctx do
      File.write!(ctx.hex_out, @hex_behind)
      File.touch!(Path.join(Path.dirname(ctx.work), "fail-compile"))

      assert {out, 0} = hooked(ctx, ["rebase", "main"])
      assert out =~ "the bump could not be committed"
      assert out =~ "The bump's changes are left in the worktree"
      assert subjects(ctx) == ["feature work", "main moves", "base"]
      assert git(ctx.work, ["diff", "--cached", "--name-only"]) == "mix.exs\nmix.lock"
    end
  end

  # An amend went through pre-commit, so post-rewrite adds no bump. Here
  # nothing is staged, so Lefthook skips pre-commit too and nothing reads the
  # Hex report.
  test "an amend gets no bump commit of its own", ctx do
    File.write!(ctx.hex_out, @hex_behind)
    stage(ctx.work, "code.txt", "change\n")
    no_hooks(ctx.work, ["commit", "-qm", "change code"])

    assert {_, 0} = commit(ctx, ["--amend", "-m", "amended"])
    assert ctx |> subjects() |> hd() == "amended"
    refute "mix hex.outdated" in run(ctx)
  end

  defp subjects(ctx), do: ctx.work |> git(["log", "--format=%s"]) |> String.split("\n")
end
