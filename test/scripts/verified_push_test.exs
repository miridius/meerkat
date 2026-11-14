defmodule Meerkat.VerifiedPushTest do
  # Runs the repo's real scripts/verified-push.ts and scripts/checked-trees.ts
  # in a fixture repo. check.ts and mutate.ts are replaced by stubs that log
  # each run and, unless told to fail, record HEAD the way the real ones do.
  # scripts/verified-push.test.ts covers which gates run on which tips; these
  # tests cover what crosses into git, the temporary worktree and signals.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, stage: 3, hook_env: 0, intercept_git: 3]

  @root File.cwd!()

  setup do
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

    for script <- ~w(verified-push.ts checked-trees.ts e2e-inputs.ts) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([work, "scripts", script]))
    end

    File.write!(Path.join([work, "scripts", "check-stub.sh"]), """
    #!/usr/bin/env bash
    echo "check.ts $* in $(git rev-parse HEAD)" >> '#{log}'
    pwd -P >> '#{dirs}'
    # Blocks only the first check, so a test can see whether a later tip is
    # still checked after an interrupt. Like the BEAM, it handles SIGINT
    # itself and exits 0. A signal that kills its sleeper fails the check,
    # even if macOS has yet to deliver that signal to this shell.
    if [ -n "${STUB_FIFO:-}" ] && [ ! -e "$STUB_FIFO.used" ]; then
      touch "$STUB_FIFO.used"
      sleep 30 &
      sleeper=$!
      trap 'kill "$sleeper"; exit 0' INT
      echo started > "$STUB_FIFO"
      wait "$sleeper" || exit
    fi
    [ -z "${STUB_FAIL:-}" ] || exit 1
    bun scripts/checked-trees.ts mark HEAD
    """)

    File.write!(Path.join([work, "scripts", "mutate-stub.sh"]), """
    #!/usr/bin/env bash
    echo "mutate.ts $* vs ${BASE_BRANCH:-} in $(git rev-parse HEAD)" >> '#{log}'
    bun scripts/checked-trees.ts --mutated mark HEAD
    """)

    # verified-push.ts runs `bun scripts/check.ts` and `bun scripts/mutate.ts`,
    # which hand over to the stubs.
    for gate <- ~w(check mutate) do
      File.write!(Path.join([work, "scripts", "#{gate}.ts"]), """
      const r = Bun.spawnSync(["bash", "scripts/#{gate}-stub.sh", ...process.argv.slice(2)], {
        stdio: ["inherit", "inherit", "inherit"],
      });
      process.exit(r.exitCode ?? 1);
      """)
    end

    File.write!(Path.join(work, "code.txt"), "base\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "base"])

    {:ok, work: work, log: log, dirs: dirs}
  end

  test "an unchecked HEAD in a clean worktree is checked, then recorded", ctx do
    commit(ctx.work, "code.txt", "rebased\n", "rebased")

    assert {out, 0} = verified_push(ctx, ["HEAD"])
    assert out =~ "checking it now"
    assert checks_run(ctx) == both_gates(git(ctx.work, ["rev-parse", "HEAD"]))
    assert {_, 0} = checked(ctx.work, "HEAD")
  end

  test "a merge commit below a checked tip is refused before any gate runs", ctx do
    merge = merge_commit(ctx.work)
    commit(ctx.work, "code.txt", "after the merge\n", "after the merge")
    mark(ctx.work, "HEAD")
    other = other_tip(ctx.work)

    assert {out, code} = verified_push(ctx, [other, "HEAD"])
    assert code != 0
    assert out =~ "merge commits are refused; rebase onto main instead"
    assert out =~ git(ctx.work, ["rev-parse", "--short", merge])
    assert checks_run(ctx) == []
  end

  test "a merge commit a remote-tracking ref holds is not refused", ctx do
    merge = merge_commit(ctx.work)
    git(ctx.work, ["update-ref", "refs/remotes/origin/feature", merge])
    commit(ctx.work, "code.txt", "after the merge\n", "after the merge")

    assert {_, 0} = verified_push(ctx, ["HEAD"])
    assert checks_run(ctx) == both_gates(git(ctx.work, ["rev-parse", "HEAD"]))
  end

  test "an untracked file is seen even when git status hides untracked files", ctx do
    git(ctx.work, ["config", "status.showUntrackedFiles", "no"])
    commit(ctx.work, "code.txt", "rebased\n", "rebased")
    File.write!(Path.join(ctx.work, "stray.txt"), "x\n")

    assert {out, code} = verified_push(ctx, ["HEAD"])
    assert code != 0
    assert out =~ "uncommitted or untracked files"
    assert checks_run(ctx) == []
  end

  test "an unchecked tip other than HEAD is checked in a temporary worktree, then recorded",
       ctx do
    other = other_tip(ctx.work)
    mark(ctx.work, "HEAD")

    assert {out, 0} = verified_push(ctx, [other])
    short = git(ctx.work, ["rev-parse", "--short", other])
    assert out =~ "#{short} has not passed the commit gate; checking it now"
    assert checks_run(ctx) == both_gates(other)
    assert {_, 0} = checked(ctx.work, other)
    assert_cleaned_up(ctx)
  end

  test "a failing check of a tip other than HEAD blocks the push and removes its worktree",
       ctx do
    other = other_tip(ctx.work)

    assert {out, code} = verified_push(ctx, [other], [{"STUB_FAIL", "1"}])
    assert code != 0
    assert out =~ "#{git(ctx.work, ["rev-parse", "--short", other])} failed the commit gate"
    assert {_, 1} = checked(ctx.work, other)
    assert_cleaned_up(ctx)
  end

  # INT as from Ctrl-C, HUP as from a closed terminal, TERM as from kill.
  for {signal, number} <- [{"INT", 2}, {"HUP", 1}, {"TERM", 15}] do
    test "SIG#{signal} during the check of a tip other than HEAD removes its temporary worktree and checks no later tip",
         ctx do
      interrupt_check(ctx, unquote(signal), unquote(number))
    end
  end

  defp interrupt_check(ctx, signal, number) do
    commit(ctx.work, "code.txt", "lower\n", "lower")
    lower = git(ctx.work, ["rev-parse", "HEAD"])
    commit(ctx.work, "code.txt", "upper\n", "upper")
    upper = git(ctx.work, ["rev-parse", "HEAD"])
    git(ctx.work, ["reset", "-q", "--hard", "HEAD~2"])
    fifo = ctx.log <> ".fifo"
    {_, 0} = System.cmd("mkfifo", [fifo])
    on_exit(fn -> Enum.each([fifo, fifo <> ".used"], &File.rm/1) end)

    # Signal the whole process group once the check has started, as Ctrl-C
    # does. A bash caller stops after SIGINT only if verified-push.ts dies of
    # it. For HUP and TERM the caller reports how verified-push.ts exited,
    # catching the signal itself: macOS can deliver it to the caller only
    # after its wait for verified-push.ts has returned.
    driver = """
    set -m
    { trap : HUP TERM; bun scripts/verified-push.ts "$1" "$2"; echo "caller carried on: $?"; } &
    read -r _ < "$3"
    kill -"$4" -- -$!
    wait $!
    """

    args = ["-c", driver, "driver", lower, upper, fifo, signal]
    assert {out, code} = run(ctx.work, args, [{"STUB_FIFO", fifo}])

    if signal == "INT" do
      assert code != 0
      refute out =~ "caller carried on"
    else
      assert out =~ "caller carried on: #{128 + number}\n"
    end

    assert checks_run(ctx) == ["check.ts --head in #{lower}"]
    assert_cleaned_up(ctx)
  end

  # A signal can reach this process while it removes a temporary worktree;
  # here it arrives from inside the removal. INT stands in for a second
  # Ctrl-C.
  for signal <- ~w(INT HUP TERM) do
    test "SIG#{signal} during the removal of a temporary worktree does not cut it short", ctx do
      wrapper = ctx.log <> ".git-wrapper"
      sent = Path.join(wrapper, "sent")
      on_exit(fn -> File.rm_rf!(wrapper) end)
      intercept_git(wrapper, "remove", ~s(touch '#{sent}'; kill -#{unquote(signal)} "$PPID"))
      other = other_tip(ctx.work)

      assert {_, 0} = verified_push(ctx, [other])
      assert File.exists?(sent)
      assert_cleaned_up(ctx)
    end
  end

  test "the check of a tip other than HEAD ignores the git location exported to hooks", ctx do
    other = other_tip(ctx.work)

    assert {_, 0} = verified_push(ctx, [other], [{"GIT_DIR", Path.join(ctx.work, ".git")}])
    assert checks_run(ctx) == both_gates(other)
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

  test "a tag of something other than a commit is skipped", ctx do
    blob = git(ctx.work, ["hash-object", "-w", "code.txt"])

    assert {_, 0} = verified_push(ctx, [blob])
    assert checks_run(ctx) == []
  end

  test "an annotated tag of an unchecked commit is checked as that commit", ctx do
    commit(ctx.work, "code.txt", "tagged\n", "tagged")
    git(ctx.work, ["tag", "-a", "-m", "release", "v1"])
    tagged = git(ctx.work, ["rev-parse", "HEAD"])
    git(ctx.work, ["reset", "-q", "--hard", "HEAD~1"])

    assert {_, code} = verified_push(ctx, ["v1"], [{"STUB_FAIL", "1"}])
    assert code != 0
    assert checks_run(ctx) == ["check.ts --head in #{tagged}"]
  end

  defp commit(work, name, content, message) do
    stage(work, name, content)
    git(work, ["commit", "-qm", message])
  end

  # Merges a side branch into HEAD and returns the merge commit.
  defp merge_commit(work) do
    git(work, ["switch", "-q", "-c", "side"])
    commit(work, "side.txt", "side\n", "side")
    git(work, ["switch", "-q", "main"])
    commit(work, "code.txt", "main\n", "main")
    git(work, ["merge", "-q", "--no-edit", "side"])
    git(work, ["rev-parse", "HEAD"])
  end

  # An unchecked commit that is not HEAD. verified-push.ts treats every such
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

  # Records rev as having passed both gates.
  defp mark(work, rev) do
    for store <- ["", "--mutated "] do
      {_, 0} = run(work, ["-c", ~s(bun scripts/checked-trees.ts #{store}mark "$1"), "mark", rev])
    end
  end

  # Exits 0 when rev is recorded as having passed both gates.
  defp checked(work, rev) do
    both =
      ~s(bun scripts/checked-trees.ts has "$1" && bun scripts/checked-trees.ts --mutated has "$1")

    run(work, ["-c", both, "checked", rev])
  end

  # What verified-push.ts logs for a commit that passes neither gate yet.
  defp both_gates(sha),
    do: ["check.ts --head in #{sha}", "mutate.ts changed vs origin/main in #{sha}"]

  defp verified_push(ctx, revs, env \\ []) do
    shas = Enum.map(revs, &git(ctx.work, ["rev-parse", &1]))
    run(ctx.work, ["-c", ~s(bun scripts/verified-push.ts "$@"), "verified-push" | shas], env)
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
