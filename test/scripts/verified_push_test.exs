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

    git(Path.dirname(work), ["init", "-q", "--initial-branch=main", work])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])
    File.mkdir_p!(Path.join(work, "scripts"))

    for script <- ~w(verified-push.sh checked-trees.sh) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([work, "scripts", script]))
    end

    File.write!(Path.join([work, "scripts", "check.sh"]), """
    #!/usr/bin/env bash
    echo "check.sh $*" >> '#{log}'
    [ -z "${STUB_FAIL:-}" ] || exit 1
    [ -n "${STUB_NO_MARK:-}" ] || bash scripts/checked-trees.sh mark HEAD
    """)

    File.write!(Path.join(work, "code.txt"), "base\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "base"])

    {:ok, work: work, log: log}
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
    assert checks_run(ctx) == ["check.sh --head"]
    assert {_, 0} = checked(ctx.work, "HEAD")
  end

  test "an unchecked HEAD whose checks fail blocks the push", ctx do
    commit(ctx.work, "code.txt", "rebased\n", "rebased")

    assert {_, code} = verified_push(ctx, ["HEAD"], [{"STUB_FAIL", "1"}])
    assert code != 0
    assert checks_run(ctx) == ["check.sh --head"]
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

  test "an unchecked tip other than HEAD is refused and named", ctx do
    commit(ctx.work, "code.txt", "other\n", "other")
    other = git(ctx.work, ["rev-parse", "HEAD"])
    git(ctx.work, ["reset", "-q", "--hard", "HEAD~1"])
    mark(ctx.work, "HEAD")

    assert {out, code} = verified_push(ctx, [other])
    assert code != 0
    short = git(ctx.work, ["rev-parse", "--short", other])
    assert out =~ "#{short} has not passed scripts/check.sh"
    assert checks_run(ctx) == []
  end

  test "an unchecked tip is refused after a checked one", ctx do
    checked = git(ctx.work, ["rev-parse", "HEAD"])
    mark(ctx.work, "HEAD")
    commit(ctx.work, "code.txt", "other\n", "other")
    other = git(ctx.work, ["rev-parse", "HEAD"])
    git(ctx.work, ["reset", "-q", "--hard", "HEAD~1"])

    assert {out, code} = verified_push(ctx, [checked, other])
    assert code != 0
    assert out =~ "#{git(ctx.work, ["rev-parse", "--short", other])} has not passed"
  end

  test "an unchecked tip is refused after a tag of something other than a commit", ctx do
    blob = git(ctx.work, ["hash-object", "-w", "code.txt"])
    commit(ctx.work, "code.txt", "other\n", "other")
    other = git(ctx.work, ["rev-parse", "HEAD"])
    git(ctx.work, ["reset", "-q", "--hard", "HEAD~1"])

    assert {_, code} = verified_push(ctx, [blob, other])
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

  test "an annotated tag of an unchecked commit is refused", ctx do
    commit(ctx.work, "code.txt", "tagged\n", "tagged")
    git(ctx.work, ["tag", "-a", "-m", "release", "v1"])
    git(ctx.work, ["reset", "-q", "--hard", "HEAD~1"])

    assert {_, code} = verified_push(ctx, ["v1"])
    assert code != 0
  end

  defp commit(work, name, content, message) do
    stage(work, name, content)
    git(work, ["commit", "-qm", message])
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
