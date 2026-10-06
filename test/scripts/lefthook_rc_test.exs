defmodule Meerkat.LefthookRcTest do
  # Runs git through the repo's real lefthook.yml, scripts/lefthook-rc.sh
  # and scripts/auto-install.sh, plus a lefthook-local.yml that adds a
  # commit-msg hook. install.sh and that hook are stubs that leave a
  # marker file when they run.
  use ExUnit.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, hook_env: 0]

  @root File.cwd!()

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-lefthook-rc")
    on_exit(fn -> File.rm_rf!(base) end)
    File.rm_rf!(Path.join(base, ".git"))

    work = Path.join(base, "work")
    marker = Path.join(base, "install-ran")
    commit_msg_marker = Path.join(base, "commit-msg-ran")

    File.mkdir_p!(Path.join(work, "scripts"))
    git(work, ["init", "-q", "--initial-branch=main"])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])

    for file <- ~w(lefthook.yml scripts/lefthook-rc.sh scripts/auto-install.sh) do
      File.cp!(Path.join(@root, file), Path.join(work, file))
    end

    File.write!(Path.join([work, "scripts", "install.sh"]), "touch '#{marker}'\n")

    File.write!(Path.join(work, "lefthook-local.yml"), """
    commit-msg:
      commands:
        stub:
          run: touch '#{commit_msg_marker}'
    """)

    Meerkat.TestHelpers.install_lefthook(work)

    no_hooks(work, ["add", "lefthook.yml", "scripts"])
    no_hooks(work, ["commit", "-qm", "base"])
    no_hooks(work, ["switch", "-q", "-c", "feature"])

    {:ok, work: work, marker: marker, commit_msg_marker: commit_msg_marker}
  end

  test "switching to main auto-installs", %{work: work, marker: marker} do
    assert {_, 0} = run(work, ["switch", "-q", "main"])
    assert File.exists?(marker)
  end

  test "a checkout without its own lefthook switches branches without error", ctx do
    File.rm_rf!(Path.join(ctx.work, "node_modules"))

    assert {out, 0} = run(ctx.work, ["switch", "-q", "-c", "other"])
    assert out =~ "HEAD=other (not main); skipping."
    refute out =~ "lefthook"
    refute File.exists?(ctx.marker)
  end

  test "a checkout without its own lefthook still auto-installs on main", ctx do
    File.rm_rf!(Path.join(ctx.work, "node_modules"))

    assert {_, 0} = run(ctx.work, ["switch", "-q", "main"])
    assert File.exists?(ctx.marker)
  end

  test "a checkout without its own lefthook makes a merge commit, skipping commit-msg", ctx do
    no_hooks(ctx.work, ["commit", "-q", "--allow-empty", "-m", "on feature"])
    no_hooks(ctx.work, ["switch", "-q", "main"])
    File.rm_rf!(Path.join(ctx.work, "node_modules"))

    assert {out, 0} = run(ctx.work, ["merge", "-q", "--no-ff", "-m", "merge", "feature"])
    refute out =~ "lefthook"
    assert git(ctx.work, ["log", "-1", "--format=%s"]) == "merge"
    refute File.exists?(ctx.commit_msg_marker)
    assert File.exists?(ctx.marker), "post-merge auto-installs on main"
  end

  test "a checkout with its own lefthook runs commit-msg on a merge commit", ctx do
    no_hooks(ctx.work, ["commit", "-q", "--allow-empty", "-m", "on feature"])
    no_hooks(ctx.work, ["switch", "-q", "main"])

    assert {_, 0} = run(ctx.work, ["merge", "-q", "--no-ff", "-m", "merge", "feature"])
    assert File.exists?(ctx.commit_msg_marker)
    assert File.exists?(ctx.marker), "post-merge auto-installs on main"
  end

  test "a checkout without its own lefthook refuses a commit, naming the setup", ctx do
    File.rm_rf!(Path.join(ctx.work, "node_modules"))
    assert_commit_refused(ctx.work, "run `mix deps.get && pnpm install`")
  end

  test "a checkout without lefthook or lefthook.yml refuses a commit", ctx do
    File.rm_rf!(Path.join(ctx.work, "node_modules"))
    File.rm!(Path.join(ctx.work, "lefthook.yml"))
    assert_commit_refused(ctx.work, "not installed")
  end

  # A wrapper, like one a hook manager installs, that runs the shim
  # under another name.
  test "a checkout without its own lefthook refuses a commit through a wrapped hook", ctx do
    hooks = Path.join(ctx.work, ".git/hooks")
    File.rename!(Path.join(hooks, "pre-commit"), Path.join(hooks, "pre-commit.orig"))
    File.write!(Path.join(hooks, "pre-commit"), ~s(#!/bin/sh\nexec "$0.orig" "$@"\n))
    File.chmod!(Path.join(hooks, "pre-commit"), 0o755)
    File.rm_rf!(Path.join(ctx.work, "node_modules"))

    assert_commit_refused(ctx.work, "not installed")
  end

  test "adding a worktree on main auto-installs in it", ctx do
    fresh = Path.join(Path.dirname(ctx.work), "fresh")

    assert {out, 0} = run(ctx.work, ["worktree", "add", "-q", fresh, "main"])
    refute out =~ "lefthook"
    assert File.exists?(ctx.marker)
  end

  test "adding a worktree on another branch skips auto-install without error", ctx do
    fresh = Path.join(Path.dirname(ctx.work), "fresh")

    assert {out, 0} = run(ctx.work, ["worktree", "add", "-q", "-b", "other", fresh])
    assert out =~ "HEAD=other (not main); skipping."
    refute out =~ "lefthook"
    refute File.exists?(ctx.marker)
  end

  defp assert_commit_refused(work, message) do
    File.write!(Path.join(work, "a.txt"), "a\n")
    no_hooks(work, ["add", "a.txt"])
    head = git(work, ["rev-parse", "HEAD"])

    assert {out, code} = run(work, ["commit", "-qm", "x"])
    assert code != 0
    assert out =~ message
    assert git(work, ["rev-parse", "HEAD"]) == head
  end

  defp run(work, args) do
    System.cmd("git", args, cd: work, env: hook_env(), stderr_to_stdout: true)
  end

  defp no_hooks(work, args), do: git(work, ["-c", "core.hooksPath=/dev/null" | args])
end
