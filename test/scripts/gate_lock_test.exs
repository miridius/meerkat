defmodule Meerkat.GateLockTest do
  # Runs the repo's real scripts/gate-lock.sh in a git repo of its own. Each
  # gate is a bash port that takes a slot, then prints a line and, where the
  # test must end it, waits for its stdin to close.
  use ExUnit.Case, async: true

  import Meerkat.TestHelpers, only: [git: 2, gate_lock_port: 2, hold_gate_slot: 1]

  @waiting "gate-lock: 2 gates are already running checks in this repo; waiting for one to finish."

  setup do
    repo = Meerkat.TestHelpers.make_git_repo("meerkat-gate-lock")
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, repo: repo}
  end

  test "a gate takes a free slot at once, saying nothing", ctx do
    gate = gate_lock_port(ctx.repo, "echo ran")

    assert_receive {^gate, {:data, {:eol, line}}}, 5_000
    assert line == "ran"
    assert_receive {^gate, {:exit_status, 0}}, 5_000
  end

  test "two gates run at once and a third waits, saying so, until one ends", ctx do
    first = hold_gate_slot(ctx.repo)
    _second = hold_gate_slot(ctx.repo)

    third = gate_lock_port(ctx.repo, "echo third ran")
    assert_receive {^third, {:data, {:eol, @waiting}}}, 5_000
    refute_receive {^third, {:data, {:eol, "third ran"}}}, 1_500

    Port.close(first)
    assert_receive {^third, {:data, {:eol, "gate-lock: got a slot after " <> _}}}, 5_000
    assert_receive {^third, {:data, {:eol, "third ran"}}}, 5_000
    assert_receive {^third, {:exit_status, 0}}, 5_000
  end

  test "gates in all worktrees of a repo share the slots", ctx do
    git(ctx.repo, ~w(-c user.name=t -c user.email=t@t.t commit -q --allow-empty -m base))
    linked = Path.join(ctx.repo, "linked")
    git(ctx.repo, ["worktree", "add", "-q", linked])

    _first = hold_gate_slot(ctx.repo)
    _second = hold_gate_slot(ctx.repo)

    gate = gate_lock_port(linked, "echo linked ran")
    assert_receive {^gate, {:data, {:eol, @waiting}}}, 5_000
  end

  test "waiting gates take free slots in the order they arrived", ctx do
    first = hold_gate_slot(ctx.repo)
    second = hold_gate_slot(ctx.repo)

    earlier = gate_lock_port(ctx.repo, "echo earlier ran; read -r _")
    assert_receive {^earlier, {:data, {:eol, @waiting}}}, 5_000
    # Which waiter polls first after a slot frees is down to timing, so
    # check that the one waiting holds the queue newcomers wait on.
    queue = Path.join(ctx.repo, ".git/meerkat-gate-lock/queue")
    assert {_, 75} = System.cmd("lockf", ["-k", "-s", "-t", "0", queue, "true"])
    later = gate_lock_port(ctx.repo, "echo later ran")
    assert_receive {^later, {:data, {:eol, @waiting}}}, 5_000

    Port.close(first)
    assert_receive {^earlier, {:data, {:eol, "earlier ran"}}}, 5_000
    refute_receive {^later, {:data, {:eol, "later ran"}}}, 1_500

    Port.close(second)
    assert_receive {^later, {:data, {:eol, "later ran"}}}, 5_000
  end

  # The kernel drops a dead process's flock, and the child, started with the
  # slot's fd closed as the gates start theirs, never held it.
  test "a gate killed by SIGKILL frees its slot, even while its child runs on", ctx do
    killed = gate_lock_port(ctx.repo, "sleep 10 9>&- & echo held; wait")
    assert_receive {^killed, {:data, {:eol, "held"}}}, 5_000
    _other = hold_gate_slot(ctx.repo)

    kill(killed)

    next = gate_lock_port(ctx.repo, "echo next ran")
    assert_receive {^next, {:data, {:eol, "next ran"}}}, 5_000
  end

  test "a waiting gate killed by SIGKILL leaves the queue to the next", ctx do
    first = hold_gate_slot(ctx.repo)
    _second = hold_gate_slot(ctx.repo)

    killed = gate_lock_port(ctx.repo, "echo killed ran")
    assert_receive {^killed, {:data, {:eol, @waiting}}}, 5_000
    later = gate_lock_port(ctx.repo, "echo later ran")
    assert_receive {^later, {:data, {:eol, @waiting}}}, 5_000

    kill(killed)
    Port.close(first)
    assert_receive {^later, {:data, {:eol, "later ran"}}}, 5_000
  end

  defp kill(port) do
    {:os_pid, pid} = Port.info(port, :os_pid)
    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(pid)])
  end
end
