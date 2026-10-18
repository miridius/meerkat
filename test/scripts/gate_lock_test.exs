defmodule Meerkat.GateLockTest do
  # Runs the repo's real scripts/gate-lock.sh in a git repo of its own. Each
  # gate is a bash port that takes a slot, then prints a line and, where the
  # test must end it, waits for its stdin to close.
  use ExUnit.Case, async: true

  import Meerkat.TestHelpers,
    only: [git: 2, gate_lock_port: 2, gate_lock_port: 3, hold_gate_slot: 1]

  @waiting "gate-lock: 2 gates are already running checks in this repo; waiting for one to finish."

  setup do
    repo = Meerkat.TestHelpers.make_git_repo("meerkat-gate-lock")
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, repo: repo}
  end

  test "a gate takes a free slot at once, saying nothing, and keeps no ticket", ctx do
    gate = gate_lock_port(ctx.repo, "echo ran")

    assert_receive {^gate, {:data, {:eol, line}}}, 5_000
    assert line == "ran"
    assert tickets(ctx.repo) == []
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

  test "waiting gates take freed slots in the order they started waiting", ctx do
    first = hold_gate_slot(ctx.repo)
    second = hold_gate_slot(ctx.repo)

    [w1, w2, w3, w4] =
      for name <- ~w(w1 w2 w3 w4) do
        gate = gate_lock_port(ctx.repo, "echo #{name} ran; read -r _")
        assert_receive {^gate, {:data, {:eol, @waiting}}}, 5_000
        gate
      end

    Port.close(first)
    assert_receive {^w1, {:data, {:eol, "w1 ran"}}}, 5_000
    refute_ran([w2, w3, w4])

    Port.close(second)
    assert_receive {^w2, {:data, {:eol, "w2 ran"}}}, 5_000
    refute_ran([w3, w4])

    Port.close(w1)
    assert_receive {^w3, {:data, {:eol, "w3 ran"}}}, 5_000
    refute_ran([w4])

    Port.close(w2)
    assert_receive {^w4, {:data, {:eol, "w4 ran"}}}, 5_000
  end

  test "a gate waits behind an earlier live ticket, even with a slot free", ctx do
    first = hold_gate_slot(ctx.repo)
    _second = hold_gate_slot(ctx.repo)
    waiting = gate_lock_port(ctx.repo, "echo waiting ran; read -r _")
    assert_receive {^waiting, {:data, {:eol, @waiting}}}, 5_000

    # A ticket held by a live process that never takes a slot stands for a
    # gate that started waiting first and has yet to poll.
    holder = hold_ticket(ctx.repo, "1000000000000000.1")
    Port.close(first)
    refute_ran([waiting])

    Port.close(holder)
    assert_receive {^waiting, {:data, {:eol, "waiting ran"}}}, 5_000
  end

  # A gate behind the head of the queue waits for an earlier ticket to go,
  # and one at the head waits for a slot; neither may burn CPU while it waits.
  test "waiting gates sleep rather than spin", ctx do
    _first = hold_gate_slot(ctx.repo)
    _second = hold_gate_slot(ctx.repo)
    head = gate_lock_port(ctx.repo, "echo head ran")
    assert_receive {^head, {:data, {:eol, @waiting}}}, 5_000
    behind = gate_lock_port(ctx.repo, "echo behind ran")
    assert_receive {^behind, {:data, {:eol, @waiting}}}, 5_000

    Process.sleep(2_000)
    assert cpu_seconds(head) < 0.5
    assert cpu_seconds(behind) < 0.5
  end

  test "a gate that gets no slot in time gives up, saying so, and leaves the queue", ctx do
    _first = hold_gate_slot(ctx.repo)
    _second = hold_gate_slot(ctx.repo)

    gate = gate_lock_port(ctx.repo, "echo ran", 1)
    assert_receive {^gate, {:data, {:eol, @waiting}}}, 5_000

    assert_receive {^gate,
                    {:data,
                     {:eol,
                      "gate-lock: no slot came free in 1s; giving up. Set MEERKAT_GATE_LOCK_TIMEOUT to wait longer."}}},
                   5_000

    assert_receive {^gate, {:exit_status, 1}}, 5_000
    assert tickets(ctx.repo) == []
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
    assert tickets(ctx.repo) == []
  end

  defp refute_ran(gates) do
    for gate <- gates, do: refute_receive({^gate, {:data, {:eol, _}}}, 1_500)
  end

  # Holds, until the returned port is closed, a locked ticket named `name`,
  # as a waiting gate does.
  defp hold_ticket(repo, name) do
    path = Path.join(repo, ".git/meerkat-gate-lock/waiting/#{name}")

    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        {:line, 4096},
        args: ["-c", ~s(exec 8>"$0"; lockf -s -t 0 8; echo held; read -r _), path]
      ])

    assert_receive {^port, {:data, {:eol, "held"}}}, 5_000
    port
  end

  defp tickets(repo), do: File.ls!(Path.join(repo, ".git/meerkat-gate-lock/waiting"))

  defp kill(port) do
    {:os_pid, pid} = Port.info(port, :os_pid)
    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(pid)])
  end

  # The CPU time, in seconds, of the port's live process tree.
  defp cpu_seconds(port) do
    {:os_pid, root} = Port.info(port, :os_pid)
    {out, 0} = System.cmd("ps", ["-A", "-o", "pid=,ppid=,time="])

    procs =
      for line <- String.split(out, "\n", trim: true),
          [pid, ppid, time] <- [String.split(line)],
          do: {String.to_integer(pid), String.to_integer(ppid), seconds(time)}

    procs |> tree([root]) |> Enum.sum()
  end

  defp tree(procs, pids) do
    children = for {pid, ppid, _} <- procs, ppid in pids, do: pid
    own = for {pid, _, time} <- procs, pid in pids, do: time
    if children == [], do: own, else: own ++ tree(procs, children)
  end

  # ps prints CPU time as [hh:]mm:ss.cc.
  defp seconds(time) do
    time
    |> String.split(":")
    |> Enum.reduce(0.0, fn part, acc -> acc * 60 + elem(Float.parse(part), 0) end)
  end
end
