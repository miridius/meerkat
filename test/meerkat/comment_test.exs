defmodule Meerkat.CommentTest do
  use ExUnit.Case, async: true

  alias Meerkat.Comment

  @uuid_v4_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  describe "new_id/0" do
    test "matches RFC 4122 v4 UUID shape" do
      # Lots of iterations — `pad_uuid` exists because the leading-
      # zeros bug already shipped once. Checking ~10k samples catches
      # any regression in the bit-fiddling.
      for _ <- 1..10_000 do
        id = Comment.new_id()

        assert Regex.match?(@uuid_v4_regex, id),
               "expected v4 UUID, got: #{inspect(id)}"
      end
    end

    test "version bits are always 4" do
      id = Comment.new_id()
      [_, _, v_field, _, _] = String.split(id, "-")
      assert String.starts_with?(v_field, "4")
    end

    test "variant bits are 8 / 9 / a / b" do
      id = Comment.new_id()
      [_, _, _, variant_field, _] = String.split(id, "-")
      assert String.at(variant_field, 0) in ["8", "9", "a", "b"]
    end

    test "ids are unique across many calls" do
      ids = for _ <- 1..1_000, do: Comment.new_id()
      assert length(Enum.uniq(ids)) == 1_000
    end
  end

  describe "finding_type?/1" do
    test "true for the five closed-set atoms" do
      assert Comment.finding_type?(:issue)
      assert Comment.finding_type?(:suggestion)
      assert Comment.finding_type?(:question)
      assert Comment.finding_type?(:follow_up)
      assert Comment.finding_type?(:revert)
    end

    test "false for adjacent strings (atoms only)" do
      refute Comment.finding_type?("issue")
      refute Comment.finding_type?("revert")
    end

    test "false for legacy / unknown atoms" do
      refute Comment.finding_type?(:thought)
      refute Comment.finding_type?(:random)
      refute Comment.finding_type?(nil)
    end
  end

  describe "finding_types/0" do
    test "returns the canonical closed set" do
      assert Comment.finding_types() == [
               :issue,
               :suggestion,
               :question,
               :follow_up,
               :revert
             ]
    end
  end

  describe "now/0" do
    test "is a valid ISO 8601 UTC timestamp" do
      s = Comment.now()
      assert {:ok, _, 0} = DateTime.from_iso8601(s)
    end
  end
end
