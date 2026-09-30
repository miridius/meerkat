defmodule Meerkat.PrePushHookTest do
  # Pushes through the repo's real lefthook.yml, .lefthook/pre-push/pre-push.sh
  # and scripts/no-private-refs.sh to a local bare remote. Only outdated.sh is
  # replaced, by a stub that records each run and exits with a chosen status.
  use ExUnit.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, stage: 3, hook_env: 0]

  @root File.cwd!()

  # Assembled from pieces: this file is itself scanned before every push.
  @private_path "/Us" <> "ers/alice/notes"

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-pre-push")
    on_exit(fn -> File.rm_rf!(base) end)
    File.rm_rf!(Path.join(base, ".git"))

    work = Path.join(base, "work")
    remote = Path.join(base, "remote.git")
    marker = Path.join(base, "outdated-ran")
    outdated_status = Path.join(base, "outdated-status")

    File.mkdir_p!(Path.join(work, "scripts"))
    File.mkdir_p!(Path.join(work, ".lefthook/pre-push"))
    git(base, ["init", "-q", "--bare", remote])
    git(work, ["init", "-q", "--initial-branch=main"])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])
    git(work, ["remote", "add", "origin", remote])

    for file <- ~w(lefthook.yml .lefthook/pre-push/pre-push.sh scripts/no-private-refs.sh) do
      File.cp!(Path.join(@root, file), Path.join(work, file))
    end

    File.write!(Path.join([work, "scripts", "outdated.sh"]), """
    #!/usr/bin/env bash
    touch '#{marker}'
    exit "$(cat '#{outdated_status}' 2>/dev/null || echo 0)"
    """)

    Meerkat.TestHelpers.install_lefthook(work)

    commit(work, "README.md", "hello\n", "base")
    no_hooks(work, ["push", "-q", "origin", "main"])

    {:ok, work: work, marker: marker, outdated_status: outdated_status}
  end

  test "a push of new commits runs the checks", %{work: work, marker: marker} do
    commit(work, "a.txt", "a\n", "add a")

    assert {_, 0} = push(work, ["origin", "HEAD:refs/heads/feature"])
    assert File.exists?(marker)
  end

  test "a failing check blocks the push", ctx do
    File.write!(ctx.outdated_status, "1")
    commit(ctx.work, "a.txt", "a\n", "add a")

    assert {_, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
  end

  test "a private reference on a branch other than the checked-out one blocks its push", ctx do
    no_hooks(ctx.work, ["switch", "-q", "-c", "leaky"])
    commit(ctx.work, "notes.txt", "see #{@private_path}\n", "add notes")
    no_hooks(ctx.work, ["switch", "-q", "main"])

    assert {out, code} = push(ctx.work, ["origin", "leaky"])
    assert code != 0
    assert out =~ "local absolute path"
    assert File.exists?(ctx.marker), "outdated.sh still runs when the other check fails"
  end

  test "a private reference only in a commit message blocks the push", %{work: work} do
    commit(work, "a.txt", "a\n", "copied from #{@private_path}")

    assert {out, code} = push(work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "in a commit message being pushed"
  end

  # lefthook skips a pre-push *command* when `git diff HEAD @{push}` is
  # empty, which is true of a force-push that changes only history.
  test "a force-push that only rewrites history runs the checks", ctx do
    no_hooks(ctx.work, ["switch", "-q", "-c", "feature"])
    commit(ctx.work, "a.txt", "a\n", "add a")
    assert {_, 0} = push(ctx.work, ["-u", "origin", "feature"])
    File.rm!(ctx.marker)

    no_hooks(ctx.work, ["commit", "-q", "--amend", "-m", "reworded"])

    assert {_, 0} = push(ctx.work, ["--force", "origin", "feature"])
    assert File.exists?(ctx.marker)
  end

  test "a force-push that only rewrites a commit message to hold a private reference is refused",
       ctx do
    no_hooks(ctx.work, ["switch", "-q", "-c", "feature"])
    commit(ctx.work, "a.txt", "a\n", "add a")
    assert {_, 0} = push(ctx.work, ["-u", "origin", "feature"])

    no_hooks(ctx.work, ["commit", "-q", "--amend", "-m", "copied from #{@private_path}"])

    assert {out, code} = push(ctx.work, ["--force", "origin", "feature"])
    assert code != 0
    assert out =~ "in a commit message being pushed"
  end

  test "deleting a remote branch skips the checks", ctx do
    commit(ctx.work, "a.txt", "a\n", "add a")
    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    File.rm!(ctx.marker)
    File.write!(ctx.outdated_status, "1")

    assert {out, 0} = push(ctx.work, ["origin", "--delete", "feature"])
    assert out =~ "only deleting remote refs; skipping checks."
    refute File.exists?(ctx.marker)
  end

  test "a push that deletes one branch and updates another runs the checks", ctx do
    commit(ctx.work, "a.txt", "a\n", "add a")
    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    File.rm!(ctx.marker)
    File.write!(ctx.outdated_status, "1")
    commit(ctx.work, "b.txt", "b\n", "add b")

    assert {_, code} = push(ctx.work, ["origin", ":feature", "HEAD:refs/heads/other"])
    assert code != 0
    assert File.exists?(ctx.marker)
  end

  test "a checkout without its own lefthook refuses the push", %{work: work, marker: marker} do
    File.rm_rf!(Path.join(work, "node_modules"))
    commit(work, "a.txt", "a\n", "add a")

    assert {_, code} = push(work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    refute File.exists?(marker)
  end

  defp push(work, args) do
    System.cmd("git", ["push" | args], cd: work, env: hook_env(), stderr_to_stdout: true)
  end

  # Only pushes go through the hooks; other commands would fire lefthook's
  # post-checkout install, whose script this fixture leaves out.
  defp no_hooks(work, args), do: git(work, ["-c", "core.hooksPath=/dev/null" | args])

  defp commit(work, name, content, message) do
    stage(work, name, content)
    no_hooks(work, ["commit", "-qm", message])
  end
end
