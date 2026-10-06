defmodule Meerkat.PublicRootTest do
  # Runs scripts/public-root.sh against real commits in a fixture repo,
  # with the fixture's own first commit standing in for the public root.
  use ExUnit.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, stage: 3, hook_env: 0]

  @script Path.join(File.cwd!(), "scripts/public-root.sh")
  @zero String.duplicate("0", 40)

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-public-root")
    on_exit(fn -> File.rm_rf!(base) end)
    File.rm_rf!(Path.join(base, ".git"))

    work = Path.join(base, "work")
    File.mkdir_p!(work)
    git(work, ["init", "-q", "--initial-branch=main"])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])
    root = commit(work, "README.md", "hello\n", "public root")

    {:ok, base: base, work: work, root: root}
  end

  test "history that starts at the public root may be pushed", %{work: work, root: root} do
    tip = commit(work, "a.txt", "a\n", "add a")

    assert {_, 0} = check(work, root, [line("refs/heads/main", tip)])
  end

  test "history with another root is refused and named", %{work: work, root: root} do
    old = orphan(work, "old")

    assert {out, 1} = check(work, root, [line("refs/heads/old", old)])
    assert out =~ "refs/heads/old would push history that does not start at the public root"
    assert out =~ old
  end

  test "a merge that joins other history to the public root is refused", ctx do
    old = orphan(ctx.work, "old")
    git(ctx.work, ["switch", "-q", "main"])
    git(ctx.work, ["merge", "-q", "--allow-unrelated-histories", "-m", "join", old])
    tip = git(ctx.work, ["rev-parse", "HEAD"])

    assert {out, 1} = check(ctx.work, ctx.root, [line("refs/heads/main", tip)])
    assert out =~ old
  end

  test "one refused ref fails a push of several", %{work: work, root: root} do
    old = orphan(work, "old")

    assert {_, 1} =
             check(work, root, [line("refs/heads/main", root), line("refs/heads/old", old)])
  end

  test "a deletion pushes nothing and passes", %{work: work, root: root} do
    assert {_, 0} = check(work, root, ["(delete) #{@zero} refs/heads/old #{root}"])
  end

  test "an object that is not a commit is refused", %{work: work, root: root} do
    blob = git(work, ["rev-parse", "HEAD:README.md"])

    assert {out, 1} = check(work, root, [line("refs/tags/blob", blob)])
    assert out =~ "refusing the push"
  end

  # The installed copy keeps the real public root, which this fixture
  # lacks, so it refuses every push here.
  test "--install makes Git refuse the push from another worktree with no hooks of its own",
       ctx do
    remote = Path.join(ctx.base, "remote.git")
    git(ctx.base, ["init", "-q", "--bare", remote])
    git(ctx.work, ["remote", "add", "origin", remote])

    assert {_, 0} = System.cmd("bash", [@script, "--install"], cd: ctx.work, env: hook_env())

    other = Path.join(ctx.base, "other")
    git(ctx.work, ["worktree", "add", "-q", "-b", "other", other])

    assert {out, code} =
             System.cmd(
               "git",
               ["-c", "core.hooksPath=/dev/null", "push", "origin", "other"],
               cd: other,
               env: List.keystore(hook_env(), "LEFTHOOK", 0, {"LEFTHOOK", "0"}),
               stderr_to_stdout: true
             )

    assert code != 0
    assert out =~ "does not start at the public root"
    assert git(ctx.base, ["--git-dir", remote, "for-each-ref"]) == ""
  end

  defp line(ref, sha), do: "#{ref} #{sha} #{ref} #{@zero}"

  defp check(work, root, lines) do
    input = Path.join(work, ".git/push-lines")
    File.write!(input, Enum.map_join(lines, &(&1 <> "\n")))

    System.cmd("bash", ["-c", ~s(bash "$0" --root "$1" < "$2"), @script, root, input],
      cd: work,
      env: hook_env(),
      stderr_to_stdout: true
    )
  end

  defp orphan(work, branch) do
    git(work, ["switch", "-q", "--orphan", branch])
    commit(work, "old.txt", "old\n", "old history")
  end

  defp commit(work, name, content, message) do
    stage(work, name, content)
    git(work, ["commit", "-qm", message])
    git(work, ["rev-parse", "HEAD"])
  end
end
