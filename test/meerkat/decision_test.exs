defmodule Meerkat.DecisionTest do
  # async: false — Decision is a singleton GenServer, mounted by the
  # main supervisor. Tests clear its state between runs via reset/0.
  use ExUnit.Case, async: false

  alias Meerkat.Decision

  setup do
    Decision.reset()
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

  describe "reset/0" do
    test "clears a submitted decision back to nil" do
      Decision.submit({:approve, []})
      assert {:approve, []} = Decision.current()

      assert :ok = Decision.reset()
      assert is_nil(Decision.current())
      # A fresh decision can be submitted after reset.
      Decision.submit({:reject, []})
      assert {:reject, []} = Decision.current()
    end
  end
end
