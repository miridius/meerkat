defmodule Meerkat.GateLockTest do
  # Runs the repo's real scripts/gate-lock.sh in a git repo of its own. Each
  # gate is a bash port that takes a slot, then prints a line and, where the
  # test must end it, waits for its stdin to close.
  use ExUnit.Case, async: true

  import Meerkat.TestHelpers,
    only: [git: 2, gate_lock_port: 2, gate_lock_port: 3, hold_gate_slot: 1]

  @waiting "gate-lock: waiting for one of this repo's 2 gate slots, behind any gates that started waiting first."

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

  # macOS's /bin/bash has no EPOCHREALTIME, so its gates count whole seconds.
  test "gates under macOS's bash 3.2 queue by the second they started waiting", ctx do
    _first = hold_gate_slot(ctx.repo)
    earlier = hold_ticket(ctx.repo, "#{System.os_time(:second) - 1}000000.1")

    old_bash = gate_lock_port(ctx.repo, "echo old bash ran; read -r _", bash: "/bin/bash")
    assert_receive {^old_bash, {:data, {:eol, @waiting}}}, 5_000
    later = gate_lock_port(ctx.repo, "echo later ran")
    assert_receive {^later, {:data, {:eol, @waiting}}}, 5_000

    # One slot is free, so if `later` sorted first it would take it.
    Port.close(earlier)
    assert_receive {^old_bash, {:data, {:eol, "old bash ran"}}}, 5_000
  end

  # A gate on the script from before tickets waits for the `queue` lock,
  # then tries the slots; the head of the tickets holds that lock.
  test "the head of the tickets keeps gates on the old script from the slots", ctx do
    first = hold_gate_slot(ctx.repo)
    _second = hold_gate_slot(ctx.repo)
    head = gate_lock_port(ctx.repo, "echo head ran; read -r _")
    assert_receive {^head, {:data, {:eol, @waiting}}}, 5_000

    old = old_script_waiter(ctx.repo)
    refute_ran([old])
    Port.close(first)
    assert_receive {^head, {:data, {:eol, "head ran"}}}, 5_000
    assert_receive {^old, {:data, {:eol, "old queued"}}}, 5_000
  end

  test "a gate lets the old script's lock go while it is not the head, then takes it back",
       ctx do
    _first = hold_gate_slot(ctx.repo)
    _second = hold_gate_slot(ctx.repo)
    head = gate_lock_port(ctx.repo, "echo head ran")
    assert_receive {^head, {:data, {:eol, @waiting}}}, 5_000
    assert await_queue(ctx.repo, :locked)

    # As a gate under bash before 5 that started in the same second would.
    ahead = hold_ticket(ctx.repo, "1000000000000000.1")
    assert await_queue(ctx.repo, :free)

    Port.close(ahead)
    assert await_queue(ctx.repo, :locked)
  end

  test "a gate takes a free slot while a gate on the old script holds its lock", ctx do
    old = old_script_waiter(ctx.repo)
    assert_receive {^old, {:data, {:eol, "old queued"}}}, 5_000

    gate = gate_lock_port(ctx.repo, "echo ran")
    assert_receive {^gate, {:data, {:eol, "ran"}}}, 5_000
    assert_receive {^gate, {:exit_status, 0}}, 5_000
  end

  test "a gate whose ticket goes missing gives up, saying so", ctx do
    _first = hold_gate_slot(ctx.repo)
    _second = hold_gate_slot(ctx.repo)
    gate = gate_lock_port(ctx.repo, "echo ran")
    assert_receive {^gate, {:data, {:eol, @waiting}}}, 5_000

    [ticket] = tickets(ctx.repo)
    File.rm!(Path.join(ctx.repo, ".git/meerkat-gate-lock/waiting/#{ticket}"))

    assert_receive {^gate, {:data, {:eol, "gate-lock: this gate's ticket " <> rest}}}, 5_000
    assert String.ends_with?(rest, "/#{ticket} is gone.")
    assert_receive {^gate, {:exit_status, 1}}, 5_000
  end

  test "a gate that cannot open an earlier ticket gives up, saying so", ctx do
    waiting = Path.join(ctx.repo, ".git/meerkat-gate-lock/waiting")
    File.mkdir_p!(waiting)
    unreadable = Path.join(waiting, "1000000000000000.1")
    File.write!(unreadable, "")
    File.chmod!(unreadable, 0o000)

    gate = gate_lock_port(ctx.repo, "echo ran")

    assert_receive {^gate, {:data, {:eol, "gate-lock: cannot open " <> rest}}}, 5_000
    assert String.ends_with?(rest, "/.git/meerkat-gate-lock/waiting/1000000000000000.1.")
    assert_receive {^gate, {:exit_status, 1}}, 5_000
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

    gate = gate_lock_port(ctx.repo, "echo ran", timeout: 1)
    assert_receive {^gate, {:data, {:eol, @waiting}}}, 5_000

    assert_receive {^gate,
                    {:data,
                     {:eol,
                      "gate-lock: got no slot in 1s; giving up. Set MEERKAT_GATE_LOCK_TIMEOUT to wait longer."}}},
                   5_000

    assert_receive {^gate, {:exit_status, 1}}, 5_000
    assert tickets(ctx.repo) == []
    queue = Path.join(ctx.repo, ".git/meerkat-gate-lock/queue")
    assert {_, 0} = System.cmd("lockf", ["-k", "-s", "-t", "0", queue, "true"])
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

  # Waits, as a gate on the script from before tickets does, for the `queue`
  # lock, then prints and holds it until the returned port is closed.
  defp old_script_waiter(repo) do
    File.mkdir_p!(Path.join(repo, ".git/meerkat-gate-lock"))

    Port.open({:spawn_executable, System.find_executable("bash")}, [
      :binary,
      {:line, 4096},
      args: [
        "-c",
        ~s(exec 8>>"$0"; for _ in {1..50}; do lockf -s -t 0 8 && echo old queued && break; sleep 0.2; done; read -r _),
        Path.join(repo, ".git/meerkat-gate-lock/queue")
      ]
    ])
  end

  # Whether the old script's `queue` lock reaches `state` within 5s.
  defp await_queue(repo, state, tries \\ 25) do
    queue = Path.join(repo, ".git/meerkat-gate-lock/queue")
    {_, status} = System.cmd("lockf", ["-k", "-s", "-t", "0", queue, "true"])

    cond do
      (status == 0 and state == :free) or (status == 75 and state == :locked) -> true
      tries == 0 -> false
      true -> Process.sleep(200) && await_queue(repo, state, tries - 1)
    end
  end

  # One window for all the gates, so each gate does not add its own.
  defp refute_ran(gates) do
    gates = Map.from_keys(gates, true)

    receive do
      {gate, {:data, {:eol, line}}} when is_map_key(gates, gate) ->
        flunk("#{inspect(gate)} printed #{line}")
    after
      1_500 -> :ok
    end
  end

  # Holds, until the returned port is closed, a locked ticket named `name`,
  # locking it before it gets its name, as a waiting gate does.
  defp hold_ticket(repo, name) do
    path = Path.join(repo, ".git/meerkat-gate-lock/waiting/#{name}")

    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        {:line, 4096},
        args: [
          "-c",
          ~s(p="${0%/*}/.held$$"; exec 8>"$p"; lockf -s -t 0 8; mv "$p" "$0"; echo held; read -r _),
          path
        ]
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
