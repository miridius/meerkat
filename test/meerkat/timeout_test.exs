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
    test "a review runs for half an hour when nothing overrides it" do
      with_env(nil, fn -> assert Timeout.limit_ms() == 30 * 60 * 1000 end)
    end

    test "MEERKAT_REVIEW_TIMEOUT sets the limit, in seconds" do
      with_env("90", fn -> assert Timeout.limit_ms() == 90_000 end)
    end

    test "a limit that is not a positive whole number of seconds is ignored" do
      for bogus <- ["", "abc", "0", "-60", "12.5", "60s"] do
        with_env(bogus, fn ->
          assert Timeout.limit_ms() == 30 * 60 * 1000,
                 "#{inspect(bogus)} should leave the default standing"
        end)
      end
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

    test "this run's own anchors survive however old they are", %{repo: repo} do
      with_run_id("current", fn -> Timeout.deadline_ms(repo, "abc123") end)
      backdate(run_dir(repo, "current"), Timeout.limit_ms() + 60_000)

      with_run_id("current", fn -> :ok = Timeout.prune_stale(repo) end)

      assert File.exists?(anchor_path(repo, "abc123", "current"))
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
    end
  end
end
