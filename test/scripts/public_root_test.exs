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

  test "PUBLIC_ROOT names this repo's root commit" do
    {shallow, 0} = System.cmd("git", ["rev-parse", "--is-shallow-repository"], env: hook_env())

    if String.trim(shallow) == "false" do
      [_, sha] = Regex.run(~r/^PUBLIC_ROOT=(\w+)$/m, File.read!(@script))
      {roots, 0} = System.cmd("git", ["rev-list", "--max-parents=0", "HEAD"], env: hook_env())
      assert sha in String.split(roots)
    end
  end

  test "history that starts at the public root may be pushed", %{work: work, root: root} do
    tip = commit(work, "a.txt", "a\n", "add a")

    assert {"", 0} = check(work, root, [line("refs/heads/main", tip)])
  end

  test "history with another root is refused and named", %{work: work, root: root} do
    old = orphan(work, "old")

    assert {out, 1} =
             check(work, root, ["refs/heads/old #{old} refs/heads/leak #{@zero}"])

    assert out =~
             "refs/heads/old would push history that does not start at the public root " <>
               "#{root} — refusing the push to refs/heads/leak"

    assert out =~ "Root commits found: #{old}"
    assert out =~ "must never be pushed"
  end

  test "replacing old history onto the public root is refused all the same", ctx do
    old = orphan(ctx.work, "old")
    git(ctx.work, ["replace", "--graft", old, ctx.root])

    assert {out, 1} = check(ctx.work, ctx.root, [line("refs/heads/old", old)])
    assert out =~ "Root commits found: #{old}"
  end

  test "grafting old history onto the public root is refused all the same", ctx do
    old = orphan(ctx.work, "old")
    File.write!(Path.join(ctx.work, ".git/info/grafts"), "#{old} #{ctx.root}\n")

    assert {out, 1} = check(ctx.work, ctx.root, [line("refs/heads/old", old)])
    assert out =~ "Root commits found: #{old}"
  end

  test "overwriting a branch the remote has with other history is refused", ctx do
    old = orphan(ctx.work, "old")

    assert {_, 1} =
             check(ctx.work, ctx.root, ["refs/heads/old #{old} refs/heads/main #{ctx.root}"])
  end

  test "an annotated tag is judged by the history it points at", ctx do
    git(ctx.work, ["tag", "-a", "-m", "public", "v1", ctx.root])
    public_tag = git(ctx.work, ["rev-parse", "v1"])
    old = orphan(ctx.work, "old")
    git(ctx.work, ["tag", "-a", "-m", "old", "v0", old])
    old_tag = git(ctx.work, ["rev-parse", "v0"])

    assert {_, 0} = check(ctx.work, ctx.root, [line("refs/tags/v1", public_tag)])
    assert {out, 1} = check(ctx.work, ctx.root, [line("refs/tags/v0", old_tag)])
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
    assert out =~ "Root commits found: (none)"
  end

  test "an object this clone lacks is refused", %{work: work, root: root} do
    missing = String.duplicate("1", 40)

    assert {out, 1} = check(work, root, [line("refs/heads/gone", missing)])
    assert out =~ "cannot list the history of refs/heads/gone — refusing the push."
    refute out =~ "does not start at the public root"
  end

  # The installed copy keeps the real public root, which this fixture
  # lacks, so it refuses every push here.
  test "--install makes Git refuse the push from another worktree with its hooks directory off",
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

  # Git passes the hook the remote's name and URL as arguments.
  test "the installed hook checks the push whatever the remote is called", ctx do
    assert {_, 0} = System.cmd("bash", [@script, "--install"], cd: ctx.work, env: hook_env())
    input = Path.join(ctx.work, ".git/push-lines")
    File.write!(input, line("refs/heads/main", ctx.root) <> "\n")

    for remote <- ["--install", "--root"] do
      assert {out, code} =
               System.cmd(
                 "git",
                 ["hook", "run", "--to-stdin=#{input}", "pre-push", "--", remote, "url"],
                 cd: ctx.work,
                 env: hook_env(),
                 stderr_to_stdout: true
               )

      assert code != 0
      assert out =~ "does not start at the public root fb5bd7f"
    end
  end

  test "checking out main refreshes the installed hook, and other branches leave it", ctx do
    scripts = Path.join(ctx.work, "scripts")
    File.mkdir_p!(scripts)
    File.cp!(@script, Path.join(scripts, "public-root.sh"))

    File.cp!(
      Path.join(Path.dirname(@script), "auto-install.sh"),
      Path.join(scripts, "auto-install.sh")
    )

    File.write!(Path.join(scripts, "install.sh"), "exit 0\n")
    installed = Path.join(ctx.work, ".git/hooks/public-root.sh")

    git(ctx.work, ["switch", "-q", "-c", "feature"])
    assert {_, 0} = auto_install(ctx.work)
    refute File.exists?(installed)

    git(ctx.work, ["switch", "-q", "main"])
    assert {_, 0} = auto_install(ctx.work)
    assert File.read!(installed) == File.read!(@script)
    assert git(ctx.work, ["hook", "list", "pre-push"]) =~ ~r/^publicroot$/m
  end

  test "--install fails when Git would not run the hook", %{work: work} do
    git(work, ["config", "hook.publicroot.enabled", "false"])

    assert {out, code} =
             System.cmd("bash", [@script, "--install"],
               cd: work,
               env: hook_env(),
               stderr_to_stdout: true
             )

    assert code != 0
    assert out =~ "Git will not run"
  end

  defp line(ref, sha), do: "#{ref} #{sha} #{ref} #{@zero}"

  defp auto_install(work) do
    System.cmd("bash", ["scripts/auto-install.sh"],
      cd: work,
      env: hook_env(),
      stderr_to_stdout: true
    )
  end

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
