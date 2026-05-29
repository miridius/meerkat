defmodule Meerkat.ReviewTargetTest do
  use ExUnit.Case, async: true

  alias Meerkat.ReviewTarget

  describe "from_opts/1" do
    test "no opts → :staged with no commit-msg" do
      assert ReviewTarget.from_opts(%{}) == {:staged, nil}
    end

    test "--commit-msg path → :staged with the path" do
      assert ReviewTarget.from_opts(%{commit_msg_path: "/tmp/MSG"}) == {:staged, "/tmp/MSG"}
    end

    test "single ref → :single_ref" do
      assert ReviewTarget.from_opts(%{positional: "HEAD"}) == {:single_ref, "HEAD"}
    end

    test "two-dot range → :range with :two_dot" do
      assert ReviewTarget.from_opts(%{positional: "main..feat"}) ==
               {:range, "main", "feat", :two_dot}
    end

    test "three-dot range → :range with :three_dot" do
      assert ReviewTarget.from_opts(%{positional: "main...feat"}) ==
               {:range, "main", "feat", :three_dot}
    end

    test "--pr → :pr with the spec" do
      assert ReviewTarget.from_opts(%{pr: "123"}) == {:pr, "123"}
    end

    test "pr precedes positional precedes commit_msg_path" do
      # All three set — pr wins, then positional, then commit_msg.
      # The CLI treats multiple targets as an arg-parse error before
      # this point, but the ordering matters when only one is set.
      assert ReviewTarget.from_opts(%{
               pr: "1",
               positional: "HEAD",
               commit_msg_path: "/tmp/m"
             }) == {:pr, "1"}

      assert ReviewTarget.from_opts(%{
               positional: "HEAD",
               commit_msg_path: "/tmp/m"
             }) == {:single_ref, "HEAD"}
    end

    test "empty-string options are treated as unset (fall through)" do
      assert ReviewTarget.from_opts(%{pr: "", positional: "HEAD"}) == {:single_ref, "HEAD"}
      assert ReviewTarget.from_opts(%{commit_msg_path: ""}) == {:staged, nil}
    end

    test "range with an empty base or head still parses" do
      assert ReviewTarget.from_opts(%{positional: "..feat"}) == {:range, "", "feat", :two_dot}
      assert ReviewTarget.from_opts(%{positional: "main.."}) == {:range, "main", "", :two_dot}
    end
  end
end
