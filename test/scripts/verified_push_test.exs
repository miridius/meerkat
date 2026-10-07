defmodule Meerkat.VerifiedPushTest do
  # Runs the repo's real scripts/verified-push.sh and scripts/checked-trees.sh
  # in a fixture repo. check.sh is replaced by a stub that logs each run and,
  # unless told to fail, records HEAD as checked the way the real one does.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, stage: 3, hook_env: 0]

  @root File.cwd!()

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    work = Meerkat.TestHelpers.make_tmp_repo("meerkat-verified-push")
    on_exit(fn -> File.rm_rf!(work) end)
    File.rm_rf!(Path.join(work, ".git"))
    log = Path.join(Path.dirname(work), Path.basename(work) <> ".log")
    on_exit(fn -> File.rm(log) end)
    # Where each check ran, so a test can see what a temporary worktree leaves.
    dirs = Path.join(Path.dirname(work), Path.basename(work) <> ".dirs")

    on_exit(fn ->
      # A temporary worktree the script failed to remove is not left behind.
      with {:ok, ran_in} <- File.read(dirs) do
        for tree <- String.split(ran_in, "\n", trim: true), Path.basename(tree) == "tree" do
          File.rm_rf!(Path.dirname(tree))
        end
      end

      File.rm(dirs)
    end)

    git(Path.dirname(work), ["init", "-q", "--initial-branch=main", work])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])
    File.mkdir_p!(Path.join(work, "scripts"))

    for script <- ~w(verified-push.sh checked-trees.sh) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([work, "scripts", script]))
    end

    File.write!(Path.join([work, "scripts", "check.sh"]), """
    #!/usr/bin/env bash
    echo "check.sh $* in $(git rev-parse HEAD)" >> '#{log}'
    pwd -P >> '#{dirs}'
    [ -z "${STUB_FIFO:-}" ] || { echo started > "$STUB_FIFO"; sleep 30; }
    [ -z "${STUB_FAIL:-}" ] || exit 1
    [ -n "${STUB_NO_MARK:-}" ] || bash scripts/checked-trees.sh mark HEAD
    """)

    File.write!(Path.join(work, "code.txt"), "base\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "base"])

    {:ok, work: work, log: log, dirs: dirs}
  end

  test "a tip already checked is pushed without checking it again", ctx do
    mark(ctx.work, "HEAD")

    assert {_, 0} = verified_push(ctx, ["HEAD"])
    assert checks_run(ctx) == []
  end

  test "a Markdown-only commit on checked contents counts as checked", ctx do
    mark(ctx.work, "HEAD")
    commit(ctx.work, "docs/guide.md", "guide\n", "docs")

    assert {_, 0} = verified_push(ctx, ["HEAD"])
    assert checks_run(ctx) == []
  end

  test "an unchecked HEAD in a clean worktree is checked, then recorded", ctx do
    commit(ctx.work, "code.txt", "rebased\n", "rebased")

    assert {out, 0} = verified_push(ctx, ["HEAD"])
    assert out =~ "checking it now"
    assert checks_run(ctx) == ["check.sh --head in #{git(ctx.work, ["rev-parse", "HEAD"])}"]
    assert {_, 0} = checked(ctx.work, "HEAD")
  end

  test "an unchecked HEAD whose checks fail blocks the push", ctx do
    commit(ctx.work, "code.txt", "rebased\n", "rebased")

    assert {_, code} = verified_push(ctx, ["HEAD"], [{"STUB_FAIL", "1"}])
    assert code != 0
    assert checks_run(ctx) == ["check.sh --head in #{git(ctx.work, ["rev-parse", "HEAD"])}"]
  end

  test "an unchecked HEAD beside an untracked file is refused unchecked", ctx do
    commit(ctx.work, "code.txt", "rebased\n", "rebased")
    File.write!(Path.join(ctx.work, "stray.txt"), "x\n")

    assert {out, code} = verified_push(ctx, ["HEAD"])
    assert code != 0
    assert out =~ "uncommitted or untracked files"
    assert checks_run(ctx) == []
  end

  test "an untracked file is seen even when git status hides untracked files", ctx do
    git(ctx.work, ["config", "status.showUntrackedFiles", "no"])
    commit(ctx.work, "code.txt", "rebased\n", "rebased")
    File.write!(Path.join(ctx.work, "stray.txt"), "x\n")

    assert {out, code} = verified_push(ctx, ["HEAD"])
    assert code != 0
    assert out =~ "uncommitted or untracked files"
  end

  test "an unchecked tip other than HEAD is checked in a temporary worktree, then recorded",
       ctx do
    other = other_tip(ctx.work)
    mark(ctx.work, "HEAD")

    assert {out, 0} = verified_push(ctx, [other])
    short = git(ctx.work, ["rev-parse", "--short", other])
    assert out =~ "#{short} has not passed scripts/check.sh; checking it now"
    assert checks_run(ctx) == ["check.sh --head in #{other}"]
    assert {_, 0} = checked(ctx.work, other)
    assert_cleaned_up(ctx)
  end

  test "a failing check of a tip other than HEAD blocks the push", ctx do
    other = other_tip(ctx.work)

    assert {out, code} = verified_push(ctx, [other], [{"STUB_FAIL", "1"}])
    assert code != 0
    assert out =~ "#{git(ctx.work, ["rev-parse", "--short", other])} failed scripts/check.sh"
    assert {_, 1} = checked(ctx.work, other)
    assert_cleaned_up(ctx)
  end

  test "a tip other than HEAD whose check records nothing blocks the push", ctx do
    other = other_tip(ctx.work)

    assert {out, code} = verified_push(ctx, [other], [{"STUB_NO_MARK", "1"}])
    assert code != 0
    assert out =~ "passed scripts/check.sh but was not recorded"
    assert_cleaned_up(ctx)
  end

  test "interrupting the check of a tip other than HEAD removes its temporary worktree", ctx do
    other = other_tip(ctx.work)
    fifo = ctx.log <> ".fifo"
    {_, 0} = System.cmd("mkfifo", [fifo])
    on_exit(fn -> File.rm(fifo) end)

    # As Ctrl-C does, interrupt the whole process group once the check has started.
    driver = """
    set -m
    bash scripts/verified-push.sh "$1" &
    read -r _ < "$2"
    kill -INT -- -$!
    wait $!
    """

    assert {_, code} =
             run(ctx.work, ["-c", driver, "driver", other, fifo], [{"STUB_FIFO", fifo}])

    assert code != 0
    assert_cleaned_up(ctx)
  end

  test "the check of a tip other than HEAD ignores the git location exported to hooks", ctx do
    other = other_tip(ctx.work)

    assert {_, 0} = verified_push(ctx, [other], [{"GIT_DIR", Path.join(ctx.work, ".git")}])
    assert checks_run(ctx) == ["check.sh --head in #{other}"]
    assert {_, 0} = checked(ctx.work, other)
  end

  test "the temporary worktree is made without running the repo's hooks", ctx do
    hooks = Path.join(ctx.work, ".git/failing-hooks")
    File.mkdir_p!(hooks)
    File.write!(Path.join(hooks, "post-checkout"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(hooks, "post-checkout"), 0o755)
    git(ctx.work, ["config", "core.hooksPath", hooks])
    other = other_tip(ctx.work)

    assert {_, 0} = verified_push(ctx, [other])
    assert {_, 0} = checked(ctx.work, other)
  end

  test "a stack's HEAD and the unchecked branch below it are both checked", ctx do
    commit(ctx.work, "code.txt", "lower\n", "lower")
    lower = git(ctx.work, ["rev-parse", "HEAD"])
    commit(ctx.work, "code.txt", "upper\n", "upper")
    upper = git(ctx.work, ["rev-parse", "HEAD"])

    assert {_, 0} = verified_push(ctx, [lower, upper])
    assert checks_run(ctx) == ["check.sh --head in #{lower}", "check.sh --head in #{upper}"]
    assert {_, 0} = checked(ctx.work, lower)
    assert {_, 0} = checked(ctx.work, upper)
  end

  test "an unchecked tip fails after a checked one", ctx do
    checked = git(ctx.work, ["rev-parse", "HEAD"])
    mark(ctx.work, "HEAD")
    other = other_tip(ctx.work)

    assert {out, code} = verified_push(ctx, [checked, other], [{"STUB_FAIL", "1"}])
    assert code != 0
    assert out =~ "#{git(ctx.work, ["rev-parse", "--short", other])} failed"
    assert checks_run(ctx) == ["check.sh --head in #{other}"]
  end

  test "an unchecked tip fails after a tag of something other than a commit", ctx do
    blob = git(ctx.work, ["hash-object", "-w", "code.txt"])
    other = other_tip(ctx.work)

    assert {_, code} = verified_push(ctx, [blob, other], [{"STUB_FAIL", "1"}])
    assert code != 0
  end

  test "an unchecked HEAD is refused when the worktree changed during its check", ctx do
    commit(ctx.work, "code.txt", "rebased\n", "rebased")

    assert {out, code} = verified_push(ctx, ["HEAD"], [{"STUB_NO_MARK", "1"}])
    assert code != 0
    assert out =~ "the worktree changed"
  end

  test "a tag of something other than a commit is skipped", ctx do
    blob = git(ctx.work, ["hash-object", "-w", "code.txt"])

    assert {_, 0} = verified_push(ctx, [blob])
    assert checks_run(ctx) == []
  end

  test "a tip git cannot read is refused", ctx do
    assert {out, code} = run(ctx.work, ["scripts/verified-push.sh", String.duplicate("1", 40)])
    assert code != 0
    assert out =~ "cannot read"
  end

  test "an annotated tag of an unchecked commit is checked as that commit", ctx do
    commit(ctx.work, "code.txt", "tagged\n", "tagged")
    git(ctx.work, ["tag", "-a", "-m", "release", "v1"])
    tagged = git(ctx.work, ["rev-parse", "HEAD"])
    git(ctx.work, ["reset", "-q", "--hard", "HEAD~1"])

    assert {_, code} = verified_push(ctx, ["v1"], [{"STUB_FAIL", "1"}])
    assert code != 0
    assert checks_run(ctx) == ["check.sh --head in #{tagged}"]
  end

  defp commit(work, name, content, message) do
    stage(work, name, content)
    git(work, ["commit", "-qm", message])
  end

  # An unchecked commit that is not HEAD. verified-push.sh treats every such
  # tip alike, whether it is a stack branch below HEAD or, as here, one HEAD
  # was reset off.
  defp other_tip(work) do
    commit(work, "code.txt", "other\n", "other")
    other = git(work, ["rev-parse", "HEAD"])
    git(work, ["reset", "-q", "--hard", "HEAD~1"])
    other
  end

  defp worktrees(work) do
    git(work, ["worktree", "list", "--porcelain"])
    |> String.split("\n")
    |> Enum.flat_map(fn
      "worktree " <> path -> [path]
      _ -> []
    end)
  end

  defp assert_cleaned_up(ctx) do
    assert worktrees(ctx.work) == [git(ctx.work, ["rev-parse", "--show-toplevel"])]
    [tree] = ctx.dirs |> File.read!() |> String.split("\n", trim: true)
    refute File.exists?(Path.dirname(tree))
  end

  defp mark(work, rev), do: {_, 0} = run(work, ["scripts/checked-trees.sh", "mark", rev])

  defp checked(work, rev), do: run(work, ["scripts/checked-trees.sh", "has", rev])

  defp verified_push(ctx, revs, env \\ []) do
    shas = Enum.map(revs, &git(ctx.work, ["rev-parse", &1]))
    run(ctx.work, ["scripts/verified-push.sh" | shas], env)
  end

  defp run(work, args, env \\ []) do
    System.cmd("bash", args, cd: work, env: hook_env() ++ env, stderr_to_stdout: true)
  end

  defp checks_run(ctx) do
    case File.read(ctx.log) do
      {:ok, log} -> String.split(log, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end
end
