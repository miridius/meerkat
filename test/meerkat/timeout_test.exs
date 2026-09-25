defmodule Meerkat.TimeoutTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Meerkat.TestHelpers

  alias Meerkat.{Persistence, ReviewState, Timeout}

  setup do
    repo = make_tmp_repo("meerkat-timeout")
    on_exit(fn -> File.rm_rf(repo) end)
    %{repo: repo}
  end

  defp with_env(value, fun) do
    previous = System.get_env("MEERKAT_REVIEW_TIMEOUT")

    if value,
      do: System.put_env("MEERKAT_REVIEW_TIMEOUT", value),
      else: System.delete_env("MEERKAT_REVIEW_TIMEOUT")

    try do
      fun.()
    after
      System.delete_env("MEERKAT_REVIEW_TIMEOUT")
      if previous, do: System.put_env("MEERKAT_REVIEW_TIMEOUT", previous)
    end
  end

  defp with_action(value, fun) do
    previous = System.get_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT")

    if value,
      do: System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", value),
      else: System.delete_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT")

    try do
      fun.()
    after
      System.delete_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT")
      if previous, do: System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", previous)
    end
  end

  defp with_run_id(value, fun) do
    previous = System.get_env("MEERKAT_RUN_ID")
    System.put_env("MEERKAT_RUN_ID", value)

    try do
      fun.()
    after
      System.delete_env("MEERKAT_RUN_ID")
      if previous, do: System.put_env("MEERKAT_RUN_ID", previous)
    end
  end

  defp run_dir(repo, run_id) do
    Path.join([repo, ".git", "meerkat-precommit", "deadlines", run_id])
  end

  defp anchor_path(repo, review_id, run_id \\ "unkeyed") do
    Path.join(run_dir(repo, run_id), review_id)
  end

  defp state_with_comment(body) do
    %ReviewState{
      comments: [
        %{
          id: "c1",
          file_index: 0,
          start_line: 3,
          end_line: 5,
          side: :new,
          body: body,
          finding_type: :issue,
          learn_from_this: false,
          created_at: "2026-05-10T00:00:00Z"
        }
      ]
    }
  end

  defp backdate(path, age_ms) do
    seconds = System.system_time(:second) - div(age_ms, 1000)
    :ok = File.touch!(path, seconds)
  end

  describe "limit_ms/0" do
    test "a review runs for an hour and a half when nothing overrides it" do
      with_env(nil, fn -> assert Timeout.limit_ms() == 90 * 60 * 1000 end)
    end

    test "MEERKAT_REVIEW_TIMEOUT sets the limit, in seconds" do
      with_env("90", fn -> assert Timeout.limit_ms() == 90_000 end)
    end

    test "a limit that is not a whole number of seconds is ignored" do
      for bogus <- ["", "abc", "-60", "12.5", "60s"] do
        with_env(bogus, fn ->
          assert Timeout.limit_ms() == 90 * 60 * 1000,
                 "#{inspect(bogus)} should leave the default standing"
        end)
      end
    end

    test "MEERKAT_REVIEW_TIMEOUT=0 disables the deadline entirely" do
      with_env("0", fn ->
        assert Timeout.limit_ms() == :infinity
        assert Timeout.disabled?()
      end)
    end

    test "the deadline is not disabled by default" do
      with_env(nil, fn -> refute Timeout.disabled?() end)
    end
  end

  describe "action/0" do
    test "a review that runs out of time waits when nothing overrides it" do
      with_action(nil, fn -> assert Timeout.action() == :wait end)
    end

    test "MEERKAT_AUTO_APPROVE_ON_TIMEOUT turns auto-approve on, ignoring case and spaces" do
      for truthy <- ["1", " True\n", "yes"] do
        with_action(truthy, fn ->
          assert Timeout.action() == :approve, "#{inspect(truthy)} should auto-approve"
        end)
      end
    end

    test "MEERKAT_AUTO_APPROVE_ON_TIMEOUT turns auto-approve off" do
      for falsy <- ["", "0", "FALSE", " no "] do
        with_action(falsy, fn ->
          assert Timeout.action() == :wait, "#{inspect(falsy)} should leave the review waiting"
        end)
      end
    end

    test "a value meerkat does not know leaves the review waiting" do
      for bogus <- ["approve", "y", "on", "2"] do
        with_action(bogus, fn ->
          assert Timeout.action() == :wait, "#{inspect(bogus)} should leave the review waiting"
        end)
      end
    end
  end

  describe "warn_if_unrecognised/0" do
    test "a value meerkat does not know is named on stderr" do
      with_action("approve", fn ->
        assert capture_io(:stderr, fn -> :ok = Timeout.warn_if_unrecognised() end) =~
                 ~s(MEERKAT_AUTO_APPROVE_ON_TIMEOUT="approve")
      end)
    end

    test "a known value, or none, prints nothing" do
      for value <- [nil, "", "true", "0"] do
        with_action(value, fn ->
          assert capture_io(:stderr, fn -> :ok = Timeout.warn_if_unrecognised() end) == "",
                 "#{inspect(value)} should print no warning"
        end)
      end
    end
  end

  describe "keep_alive/1" do
    test "a run past its limit that is still open survives another run's prune",
         %{repo: repo} do
      with_run_id("overdue", fn -> Timeout.deadline_ms(repo, "abc123") end)
      backdate(run_dir(repo, "overdue"), Timeout.limit_ms() + 60_000)

      with_run_id("overdue", fn -> :ok = Timeout.keep_alive(repo) end)
      with_run_id("current", fn -> :ok = Timeout.prune_stale(repo) end)

      assert File.exists?(anchor_path(repo, "abc123", "overdue"))
    end

    test "a run with no deadline directory is left without one", %{repo: repo} do
      with_run_id("fresh", fn -> :ok = Timeout.keep_alive(repo) end)

      refute File.exists?(run_dir(repo, "fresh"))
    end

    test "a repo it cannot touch costs the review nothing" do
      assert :ok = Timeout.keep_alive(nil)
    end
  end

  describe "deadline_ms/2 with the deadline disabled" do
    test "MEERKAT_REVIEW_TIMEOUT=0 arms no deadline at all", %{repo: repo} do
      with_env("0", fn ->
        assert Timeout.deadline_ms(repo, "abc123") == nil
      end)
    end
  end

  describe "deadline_ms/2" do
    test "the deadline is the limit measured from the first call", %{repo: repo} do
      before = System.system_time(:millisecond)
      deadline = Timeout.deadline_ms(repo, "abc123")

      assert deadline >= before + Timeout.limit_ms()
      assert deadline <= System.system_time(:millisecond) + Timeout.limit_ms()
    end

    test "a later call re-reads the first call's anchor rather than restarting the clock",
         %{repo: repo} do
      first = Timeout.deadline_ms(repo, "abc123")
      Process.sleep(20)

      assert Timeout.deadline_ms(repo, "abc123") == first
    end

    test "each review is anchored on its own start", %{repo: repo} do
      one = Timeout.deadline_ms(repo, "abc123")
      Process.sleep(20)

      assert Timeout.deadline_ms(repo, "def456") > one
    end

    test "an unreadable anchor is replaced rather than crashing the review", %{repo: repo} do
      _ = Timeout.deadline_ms(repo, "abc123")
      path = anchor_path(repo, "abc123")
      File.write!(path, "not a timestamp")
      before = System.system_time(:millisecond)

      deadline = Timeout.deadline_ms(repo, "abc123")

      assert deadline >= before + Timeout.limit_ms()
      assert {_, ""} = Integer.parse(File.read!(path))
    end
  end

  describe "the anchor is keyed on the launcher run" do
    test "a second run of the same review starts its own clock", %{repo: repo} do
      first = with_run_id("run-one", fn -> Timeout.deadline_ms(repo, "abc123") end)
      Process.sleep(20)

      assert with_run_id("run-two", fn -> Timeout.deadline_ms(repo, "abc123") end) > first
    end

    test "a respawn within one run resumes the remaining time", %{repo: repo} do
      first = with_run_id("run-one", fn -> Timeout.deadline_ms(repo, "abc123") end)
      Process.sleep(20)

      assert with_run_id("run-one", fn -> Timeout.deadline_ms(repo, "abc123") end) == first
    end
  end

  describe "prune_stale/1" do
    test "an abandoned run's anchors are deleted once they outlive the limit", %{repo: repo} do
      with_run_id("abandoned", fn -> Timeout.deadline_ms(repo, "abc123") end)
      backdate(run_dir(repo, "abandoned"), Timeout.limit_ms() + 60_000)

      with_run_id("current", fn -> :ok = Timeout.prune_stale(repo) end)

      refute File.exists?(run_dir(repo, "abandoned"))
    end

    test "a run younger than the limit is left alone", %{repo: repo} do
      with_run_id("recent", fn -> Timeout.deadline_ms(repo, "abc123") end)

      with_run_id("current", fn -> :ok = Timeout.prune_stale(repo) end)

      assert File.exists?(run_dir(repo, "recent"))
    end

    test "a run just past the limit is kept until its own deadline check can mark it recent",
         %{repo: repo} do
      with_run_id("overdue", fn -> Timeout.deadline_ms(repo, "abc123") end)
      backdate(run_dir(repo, "overdue"), Timeout.limit_ms() + Timeout.check_interval_ms())

      with_run_id("current", fn -> :ok = Timeout.prune_stale(repo) end)

      assert File.exists?(anchor_path(repo, "abc123", "overdue"))
    end

    test "a repo that has never held an anchor is pruned without error", %{repo: repo} do
      repo |> run_dir("any") |> Path.dirname() |> File.rm_rf!()

      assert with_run_id("current", fn -> Timeout.prune_stale(repo) end) == :ok
    end

    test "this run's own anchors survive however old they are", %{repo: repo} do
      with_run_id("current", fn -> Timeout.deadline_ms(repo, "abc123") end)
      backdate(run_dir(repo, "current"), Timeout.limit_ms() + 60_000)

      with_run_id("current", fn -> :ok = Timeout.prune_stale(repo) end)

      assert File.exists?(anchor_path(repo, "abc123", "current"))
    end

    test "an entry that cannot be stat'ed is skipped and later runs still prune", %{repo: repo} do
      # A run dir vanishing between the ls and the stat must cost only
      # itself, not the rest of the sweep. The vanished entry is named to
      # sort first so the race is exercised deterministically.
      deadlines = repo |> run_dir("any") |> Path.dirname()
      File.mkdir_p!(deadlines)
      File.ln_s("gone-#{System.unique_integer()}", Path.join(deadlines, "0-vanished"))

      for name <- ["1-stale", "2-stale"] do
        with_run_id(name, fn -> Timeout.deadline_ms(repo, "abc123") end)
        backdate(run_dir(repo, name), Timeout.limit_ms() + 60_000)
      end

      with_run_id("current", fn -> :ok = Timeout.prune_stale(repo) end)

      refute File.exists?(run_dir(repo, "1-stale"))
      refute File.exists?(run_dir(repo, "2-stale"))
    end

    test "a disabled deadline prunes nothing — a live run's anchor has no stale age", %{
      repo: repo
    } do
      with_run_id("abandoned", fn -> Timeout.deadline_ms(repo, "abc123") end)
      backdate(run_dir(repo, "abandoned"), 30 * 60 * 1000 + 60_000)

      with_env("0", fn -> assert :ok = Timeout.prune_stale(repo) end)

      assert File.exists?(run_dir(repo, "abandoned"))
    end
  end

  describe "expired?/1" do
    test "a deadline in the past has expired, one in the future has not" do
      now = System.system_time(:millisecond)

      assert Timeout.expired?(now - 1)
      refute Timeout.expired?(now + 60_000)
    end
  end

  describe "clear/2" do
    test "clearing lets the next review of the same id start a fresh clock", %{repo: repo} do
      first = Timeout.deadline_ms(repo, "abc123")
      Process.sleep(20)
      :ok = Timeout.clear(repo, "abc123")

      assert Timeout.deadline_ms(repo, "abc123") > first
    end

    test "clearing an anchor that was never written is not an error", %{repo: repo} do
      assert :ok = Timeout.clear(repo, "never-started")
    end
  end

  describe "decision/2" do
    test "with no review state to read, the timeout carries no feedback", %{repo: repo} do
      Application.delete_env(:meerkat, :review_state)

      assert {:timeout, ""} = Timeout.decision(repo, "abc123")
    end

    test "with no review state to read, no comments are reported lost", %{repo: repo} do
      Application.delete_env(:meerkat, :review_state)

      warning =
        capture_io(:stderr, fn ->
          send(self(), {:decision, Timeout.decision(repo, "abc123")})
        end)

      assert_received {:decision, {:timeout, ""}}
      assert warning == ""
    end

    test "comments saved with no browser connected still reach the agent", %{repo: repo} do
      :ok = Persistence.save(repo, "abc123", state_with_comment("tighten this"))
      Application.put_env(:meerkat, :review_state, %ReviewState{})
      on_exit(fn -> Application.delete_env(:meerkat, :review_state) end)

      assert {:timeout, payload} = Timeout.decision(repo, "abc123")
      assert payload =~ "tighten this"
      assert payload =~ "Nobody reviewed this commit"
    end

    test "a snapshot the loader cannot make sense of costs the commit nothing", %{repo: repo} do
      :ok = Persistence.save(repo, "abc123", state_with_comment("tighten this"))
      Application.put_env(:meerkat, :review_state, %ReviewState{})
      on_exit(fn -> Application.delete_env(:meerkat, :review_state) end)
      File.write!(Persistence.path_for(repo, "abc123"), ~s({"comments": [{"id": "c1"}]}))

      warning =
        capture_io(:stderr, fn ->
          send(self(), {:decision, Timeout.decision(repo, "abc123")})
        end)

      assert_received {:decision, {:timeout, ""}}

      assert warning =~ "couldn't read the comments saved for abc123",
             "the commit is told its comments were lost rather than losing them silently"

      assert warning =~ "Auto-approving without them."
    end
  end
end
