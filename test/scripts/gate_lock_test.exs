defmodule Meerkat.GateLockTest do
  # Runs the repo's real scripts/gate-lock.pl against a lock dir of its own.
  # Each gate is a port whose command prints a line once it runs and, where
  # the test must end it, waits for its stdin to close.
  use ExUnit.Case, async: true

  import Meerkat.TestHelpers, only: [gate_lock_port: 2, hold_gate_slot: 1]

  @script Path.expand("../../scripts/gate-lock.pl", __DIR__)
  @waiting "gate-lock: 2 gates are already running checks in this repo; waiting for one to finish."

  setup do
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-gate-lock")
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, lock: Path.join(base, "lock")}
  end

  test "runs the command with the lock dir in MEERKAT_GATE_LOCK and exits as it does", ctx do
    assert {out, 3} =
             System.cmd(
               "perl",
               [@script, ctx.lock, "bash", "-c", ~s(echo "$MEERKAT_GATE_LOCK"; exit 3)],
               stderr_to_stdout: true
             )

    assert out == ctx.lock <> "\n"
  end

  test "two gates run at once and a third waits, saying so, until one ends", ctx do
    first = hold_gate_slot(ctx.lock)
    _second = hold_gate_slot(ctx.lock)

    third = gate_lock_port(ctx.lock, ["bash", "-c", "echo third ran"])
    assert_receive {^third, {:data, {:eol, @waiting}}}, 5_000
    refute_receive {^third, {:data, {:eol, "third ran"}}}, 1_500

    Port.close(first)
    assert_receive {^third, {:data, {:eol, "third ran"}}}, 5_000
    assert_receive {^third, {:exit_status, 0}}, 5_000
  end

  test "waiting gates take free slots in the order they arrived", ctx do
    first = hold_gate_slot(ctx.lock)
    second = hold_gate_slot(ctx.lock)

    earlier = gate_lock_port(ctx.lock, ["bash", "-c", "echo earlier ran; read -r _"])
    assert_receive {^earlier, {:data, {:eol, @waiting}}}, 5_000
    later = gate_lock_port(ctx.lock, ["bash", "-c", "echo later ran"])
    assert_receive {^later, {:data, {:eol, @waiting}}}, 5_000

    Port.close(first)
    assert_receive {^earlier, {:data, {:eol, "earlier ran"}}}, 5_000
    refute_receive {^later, {:data, {:eol, "later ran"}}}, 1_500

    Port.close(second)
    assert_receive {^later, {:data, {:eol, "later ran"}}}, 5_000
  end

  # The kernel drops a dead process's flock, and the command, which outlives
  # it here, never held the lock.
  test "a gate killed by SIGKILL frees its slot, even while its command runs on", ctx do
    killed = hold_gate_slot(ctx.lock)
    _other = hold_gate_slot(ctx.lock)

    {:os_pid, pid} = Port.info(killed, :os_pid)
    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(pid)])

    next = gate_lock_port(ctx.lock, ["bash", "-c", "echo next ran"])
    assert_receive {^next, {:data, {:eol, "next ran"}}}, 5_000
  end

  test "dies by the signal that killed its command", ctx do
    # Prints the signal that ended the gate, or 0 if it exited.
    report = "system(@ARGV); print $? & 127"

    assert {"2", 0} =
             System.cmd("perl", [
               "-e",
               report,
               "perl",
               @script,
               ctx.lock,
               "bash",
               "-c",
               "kill -INT $$"
             ])
  end

  test "passes a SIGTERM sent to it alone on to its command", ctx do
    command = "trap 'echo got TERM; kill $!; exit 0' TERM; echo held; sleep 30 & wait $!"
    gate = gate_lock_port(ctx.lock, ["bash", "-c", command])
    assert_receive {^gate, {:data, {:eol, "held"}}}, 5_000

    {:os_pid, pid} = Port.info(gate, :os_pid)
    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(pid)])

    assert_receive {^gate, {:data, {:eol, "got TERM"}}}, 5_000
    assert_receive {^gate, {:exit_status, 0}}, 5_000
  end
end
