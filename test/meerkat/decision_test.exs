defmodule Meerkat.DecisionTest do
  # async: false — Decision is a singleton GenServer, mounted by the
  # main supervisor. Tests clear its state between runs via reset/0.
  use ExUnit.Case, async: false

  # Surviving muex mutants in decision.ex, and why none is a test gap:
  # - decision.ex:2 (delete the `@moduledoc`) — documentation only; no behaviour.
  # - decision.ex:256 handle_info/2 (delete `Logger.warning` in the catch-all
  #   clause) — changes only log output.
  # - decision.ex:290 arm_deadline/1 (`unless was_armed?` → `if`) — muex reports
  #   this as surviving, but "a deadline armed by an attach ends the review once
  #   it passes" fails against it under every seed tried. muex's timed-out mutants
  #   make its result unreliable here.

  alias Meerkat.Decision

  setup do
    Decision.reset()
    :ok
  end

  describe "submit/1 + await/0" do
    test "a second submit is refused and told which decision stands" do
      assert {:ok, {:approve, []}} = Decision.submit({:approve, []})

      assert {:already_decided, {:approve, []}} =
               Decision.submit({:reject, [reason: "too late"]})

      assert {:approve, []} = Decision.await()
      assert {:approve, []} = Decision.current()
    end

    test "await/0 blocks until submit/1 fires" do
      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)

      # Without a submit, the spawned process is still blocked.
      refute_receive {:awaited, _}, 50

      {:ok, _} = Decision.submit({:reject, [comments: ["nope"]]})
      assert_receive {:awaited, {:reject, [comments: ["nope"]]}}, 200
    end

    test "current/0 is nil before submit, decision after" do
      assert is_nil(Decision.current())
      Decision.submit({:cancel, nil})
      assert {:cancel, nil} = Decision.current()
    end
  end

  describe "the review deadline" do
    setup do
      Application.put_env(:meerkat, :deadline_check_ms, 5)
      previous_action = System.get_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT")
      System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", "true")

      on_exit(fn ->
        Application.delete_env(:meerkat, :deadline_check_ms)
        Application.delete_env(:meerkat, :review_deadline_ms)
        System.delete_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT")

        if previous_action,
          do: System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", previous_action)

        Decision.reset()
      end)

      :ok
    end

    test "a deadline already past leaves the review open when auto-approve is off" do
      System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", "false")
      Application.put_env(:meerkat, :review_deadline_ms, System.system_time(:millisecond) - 1)
      Decision.reset()

      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)

      # Outlives several deadline checks (`deadline_check_ms` is 5ms here).
      refute_receive {:awaited, _}, 100
      assert {:ok, {:approve, ""}} = Decision.submit({:approve, ""})
      assert_receive {:awaited, {:approve, ""}}, 200
    end

    test "an overdue review left open keeps its deadline directory recent" do
      repo = Meerkat.TestHelpers.make_tmp_repo("meerkat-decision")
      Application.put_env(:meerkat, :repo_path, repo)

      on_exit(fn ->
        Application.delete_env(:meerkat, :repo_path)
        File.rm_rf(repo)
      end)

      System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", "false")
      Meerkat.Timeout.deadline_ms(repo, "abc123")
      run_dir = Path.join([repo, ".git", "meerkat-precommit", "deadlines", "unkeyed"])
      backdated_s = System.system_time(:second) - 3600
      File.touch!(run_dir, backdated_s)

      Application.put_env(:meerkat, :review_deadline_ms, System.system_time(:millisecond) - 1)
      Decision.reset()
      Process.sleep(100)

      %File.Stat{mtime: mtime} = File.stat!(run_dir, time: :posix)
      assert mtime > backdated_s
    end

    test "a deadline already past ends the review without anyone clicking" do
      Application.put_env(:meerkat, :review_deadline_ms, System.system_time(:millisecond) - 1)
      Decision.reset()

      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)

      assert_receive {:awaited, {:timeout, ""}}, 1000
    end

    test "a deadline still ahead leaves the review open" do
      Application.put_env(
        :meerkat,
        :review_deadline_ms,
        System.system_time(:millisecond) + 60_000
      )

      Decision.reset()

      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)

      refute_receive {:awaited, _}, 100
    end

    test "a disabled deadline (nil) never auto-approves, however long the review runs" do
      # cli.ex arms `review_deadline_ms` only when `Timeout.deadline_ms/2`
      # returns one; disabled, it is nil and no tick ever fires.
      Application.put_env(:meerkat, :review_deadline_ms, nil)
      Decision.reset()

      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)

      # Outlives several deadline checks (`deadline_check_ms` is 5ms here).
      refute_receive {:awaited, {:timeout, _}}, 100
    end

    test "a click before the deadline is the decision the review keeps" do
      Application.put_env(
        :meerkat,
        :review_deadline_ms,
        System.system_time(:millisecond) + 60_000
      )

      Decision.reset()
      assert {:ok, {:approve, ""}} = Decision.submit({:approve, ""})

      Process.sleep(30)

      assert {:approve, ""} = Decision.current()
    end

    test "a click after the deadline is refused and told the review timed out" do
      Application.put_env(:meerkat, :review_deadline_ms, System.system_time(:millisecond) - 1)
      Decision.reset()

      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)
      assert_receive {:awaited, {:timeout, _}}, 1000

      assert {:already_decided, {:timeout, _}} =
               Decision.submit({:reject, "please fix the thing"})

      assert {:timeout, _} = Decision.current()
    end
  end

  describe "callers" do
    import Meerkat.TestHelpers

    setup do
      repo = make_tmp_repo("meerkat-decision-callers")
      Application.put_env(:meerkat, :repo_path, repo)
      Application.put_env(:meerkat, :review_id, "abc123")
      Application.put_env(:meerkat, :deadline_check_ms, 5)
      previous = System.get_env("MEERKAT_REVIEW_TIMEOUT")
      previous_action = System.get_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT")
      System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", "true")

      on_exit(fn ->
        if previous,
          do: System.put_env("MEERKAT_REVIEW_TIMEOUT", previous),
          else: System.delete_env("MEERKAT_REVIEW_TIMEOUT")

        if previous_action,
          do: System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", previous_action),
          else: System.delete_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT")

        Enum.each(
          [:repo_path, :review_id, :deadline_check_ms, :review_deadline_ms],
          &Application.delete_env(:meerkat, &1)
        )

        Decision.reset()
        File.rm_rf(repo)
      end)

      Application.put_env(:meerkat, :review_deadline_ms, nil)
      Decision.reset()
      %{repo: repo}
    end

    defp spawn_caller(run_id) do
      parent = self()

      pid =
        spawn(fn ->
          send(parent, {:attached, self(), Decision.attach(run_id)})

          receive do
            {:meerkat_outcome, outcome} -> send(parent, {:outcome, self(), outcome})
            :meerkat_displaced -> send(parent, {:displaced, self()})
          end

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:attached, ^pid, reply}, 1000
      {pid, reply}
    end

    test "an attached caller is sent the outcome once it is published" do
      {pid, reply} = spawn_caller("run-a")
      assert reply == {:ok, nil}

      :ok = Decision.publish({1, "feedback\n"})
      assert_receive {:outcome, ^pid, {1, "feedback\n"}}, 1000
    end

    test "a caller for another run displaces the one attached before it" do
      {first, _} = spawn_caller("run-a")
      {second, _} = spawn_caller("run-b")
      assert_receive {:displaced, ^first}, 1000

      :ok = Decision.publish({0, "approved\n"})
      assert_receive {:outcome, ^second, {0, "approved\n"}}, 1000
      refute_receive {:outcome, ^first, _}, 100
    end

    test "a caller reattaching for its own run displaces nobody" do
      {first, _} = spawn_caller("run-a")
      {_again, _} = spawn_caller("run-a")
      refute_receive {:displaced, ^first}, 100
    end

    test "an outcome published with nobody attached is held for the next caller" do
      :ok = Decision.publish({0, "approved\n"})

      {_pid, reply} = spawn_caller("run-b")
      assert reply == {:ok, {0, "approved\n"}}
    end

    test "a delivery wakes the CLI with the delivering run, and later callers are turned away" do
      parent = self()
      spawn_link(fn -> send(parent, {:delivered_to, Decision.await_delivery()}) end)

      assert Decision.delivered("run-c") == {:error, :no_outcome}
      refute_receive {:delivered_to, _}, 50

      :ok = Decision.publish({0, "approved\n"})
      assert Decision.delivered("run-c") == :ok
      assert_receive {:delivered_to, "run-c"}, 1000
      assert Decision.attach("run-d") == :closing
    end

    test "a delivery reported before the CLI waits for one is handed to it when it does" do
      :ok = Decision.publish({0, "approved\n"})
      :ok = Decision.delivered("run-e")
      assert Decision.await_delivery() == "run-e"
    end

    test "an outcome without an integer exit code and a text is refused" do
      for outcome <- [{"1", "feedback\n"}, {1, :feedback}] do
        assert_raise FunctionClauseError, fn -> apply(Decision, :publish, [outcome]) end
      end
    end

    test "the deadline runs only while a caller is attached" do
      System.put_env("MEERKAT_REVIEW_TIMEOUT", "600")
      {pid, _} = spawn_caller("run-e")

      armed = Application.get_env(:meerkat, :review_deadline_ms)
      assert is_integer(armed), "attaching arms the deadline"
      assert armed > System.system_time(:millisecond) + 590_000

      Process.exit(pid, :kill)

      Enum.find_value(1..100, fn _ ->
        Process.sleep(10)
        is_nil(Application.get_env(:meerkat, :review_deadline_ms))
      end)

      assert Application.get_env(:meerkat, :review_deadline_ms) == nil,
             "the last caller leaving disarms the deadline"
    end

    test "a deadline armed by an attach ends the review once it passes" do
      System.put_env("MEERKAT_REVIEW_TIMEOUT", "1")
      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)
      {_pid, _} = spawn_caller("run-f")

      assert_receive {:awaited, {:timeout, _}}, 3000
    end

    test "an overdue review left open keeps its attached caller's deadline directory recent",
         %{repo: repo} do
      System.put_env("MEERKAT_REVIEW_TIMEOUT", "1")
      System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", "false")
      {_pid, _} = spawn_caller("run-h")
      run_dir = Path.join([repo, ".git", "meerkat-precommit", "deadlines", "run-h"])
      backdated_s = System.system_time(:second) - 3600
      File.touch!(run_dir, backdated_s)

      Process.sleep(1200)

      %File.Stat{mtime: mtime} = File.stat!(run_dir, time: :posix)
      assert mtime > backdated_s
    end

    test "a review whose caller has left does not time out" do
      System.put_env("MEERKAT_REVIEW_TIMEOUT", "1")
      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)
      {pid, _} = spawn_caller("run-g")
      Process.exit(pid, :kill)

      refute_receive {:awaited, _}, 1500
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
