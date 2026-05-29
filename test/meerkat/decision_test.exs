defmodule Meerkat.DecisionTest do
  # async: false — Decision is a singleton GenServer, mounted by the
  # main supervisor. Tests reset its state between runs by stopping
  # and restarting the named process.
  use ExUnit.Case, async: false

  alias Meerkat.Decision

  setup do
    # Fresh GenServer state per test. The supervised one is fine to
    # restart — nothing else relies on its identity within :test.
    if Process.whereis(Decision) do
      :ok = GenServer.stop(Decision)
      :ok = wait_for_restart(Decision)
    end

    :ok
  end

  describe "submit/1 + await/0" do
    test "first submit wins; subsequent submits are ignored" do
      assert :ok = Decision.submit({:approve, []})
      assert :ok = Decision.submit({:reject, [reason: "too late"]})
      assert {:approve, []} = Decision.await()
      assert {:approve, []} = Decision.current()
    end

    test "await/0 blocks until submit/1 fires" do
      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)

      # Without a submit, the spawned process is still blocked.
      refute_receive {:awaited, _}, 50

      :ok = Decision.submit({:reject, [comments: ["nope"]]})
      assert_receive {:awaited, {:reject, [comments: ["nope"]]}}, 200
    end

    test "current/0 is nil before submit, decision after" do
      assert is_nil(Decision.current())
      Decision.submit({:cancel, nil})
      assert {:cancel, nil} = Decision.current()
    end
  end

  defp wait_for_restart(name, attempts \\ 50)
  defp wait_for_restart(_name, 0), do: :timeout

  defp wait_for_restart(name, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> :ok
      _ -> Process.sleep(10) && wait_for_restart(name, attempts - 1)
    end
  end
end
