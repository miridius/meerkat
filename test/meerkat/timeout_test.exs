defmodule Meerkat.TimeoutTest do
  use ExUnit.Case, async: false

  import Meerkat.TestHelpers

  alias Meerkat.Timeout

  setup do
    repo = make_tmp_repo("meerkat-timeout")
    on_exit(fn -> File.rm_rf(repo) end)
    %{repo: repo}
  end

  defp with_env(value, fun) do
    previous = System.get_env("MEERKAT_REVIEW_TIMEOUT")
    if value, do: System.put_env("MEERKAT_REVIEW_TIMEOUT", value)

    try do
      fun.()
    after
      System.delete_env("MEERKAT_REVIEW_TIMEOUT")
      if previous, do: System.put_env("MEERKAT_REVIEW_TIMEOUT", previous)
    end
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
      path = Path.join([repo, ".git", "meerkat-precommit", "deadlines", "abc123"])
      File.write!(path, "not a timestamp")

      assert Timeout.deadline_ms(repo, "abc123") >= System.system_time(:millisecond)
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
  end
end
