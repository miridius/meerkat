defmodule Meerkat.CallerTest do
  use ExUnit.Case, async: true

  alias Meerkat.Caller

  setup do
    dir = Path.join(System.tmp_dir!(), "meerkat-caller-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # A shell running `sleep`, named `name` in its command line. The trailing
  # `true` stops the shell exec'ing sleep in its place.
  defp start_process(name) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "sleep 30; true", name]])

    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", [to_string(pid)], stderr_to_stdout: true) end)
    pid
  end

  defp record(dir, pid), do: File.write!(Path.join(dir, "caller"), "#{pid}\n")

  # Like the launcher's own check, either capitalisation counts.
  test "a recorded caller running meerkat is not gone", %{dir: dir} do
    record(dir, start_process("meerkat-attach"))
    refute Caller.gone?(dir)
    record(dir, start_process("/Apps/Meerkat"))
    refute Caller.gone?(dir)
  end

  test "a recorded caller that exited is gone", %{dir: dir} do
    {out, 0} = System.cmd("/bin/sh", ["-c", "echo $$"])
    record(dir, String.trim(out))
    assert Caller.gone?(dir)
  end

  test "a recorded pid now running something other than meerkat is gone", %{dir: dir} do
    record(dir, start_process("something-else"))
    assert Caller.gone?(dir)
  end

  test "a caller ps cannot see is not gone while ps cannot see this BEAM either", %{dir: dir} do
    {out, 0} = System.cmd("/bin/sh", ["-c", "echo $$"])
    record(dir, String.trim(out))
    refute Caller.gone?(dir, fn _pid -> "" end)
  end

  test "command/2 gives a running process's command line alone, and nothing for an exited one" do
    assert Caller.command(System.pid(), "ps") =~ "beam"
    {out, 0} = System.cmd("/bin/sh", ["-c", "echo $$"])
    assert Caller.command(String.trim(out)) == ""
  end

  test "a ps that cannot run sees no process" do
    assert Caller.command(System.pid(), "/nonexistent/ps") == ""
  end

  test "a missing or unreadable caller file says nothing is gone", %{dir: dir} do
    refute Caller.gone?(dir)
    File.write!(Path.join(dir, "caller"), "")
    refute Caller.gone?(dir)
    File.write!(Path.join(dir, "caller"), "12x\n")
    refute Caller.gone?(dir)
  end
end
