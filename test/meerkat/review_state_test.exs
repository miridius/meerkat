defmodule Meerkat.ReviewStateTest do
  use ExUnit.Case, async: true

  alias Meerkat.ReviewState

  describe "blocks/1 — top-level commit-message block detection" do
    test "empty message produces no blocks" do
      assert ReviewState.blocks("") == []
    end

    test "single subject line is one block" do
      assert ReviewState.blocks("Subject only") == [
               %{start_line: 1, end_line: 1, text: "Subject only"}
             ]
    end

    test "subject + body produces two blocks separated by the blank line" do
      msg = "Subject\n\nBody paragraph."

      assert ReviewState.blocks(msg) == [
               %{start_line: 1, end_line: 1, text: "Subject"},
               %{start_line: 3, end_line: 3, text: "Body paragraph."}
             ]
    end

    test "multi-line body collapses into one block with span" do
      msg = "Subject\n\nLine three.\nLine four."

      assert ReviewState.blocks(msg) == [
               %{start_line: 1, end_line: 1, text: "Subject"},
               %{start_line: 3, end_line: 4, text: "Line three.\nLine four."}
             ]
    end

    test "list paragraph splits each item into its own block" do
      msg = """
      Subject

      - bullet one
      - bullet two
      """

      blocks = ReviewState.blocks(String.trim_trailing(msg))

      assert [
               %{start_line: 1, end_line: 1, text: "Subject"},
               %{start_line: 3, end_line: 3, text: "- bullet one"},
               %{start_line: 4, end_line: 4, text: "- bullet two"}
             ] = blocks
    end

    test "smoke-fixture-shaped commit message: subject + 2-line body + 2 bullets" do
      # Mirrors DEFAULT_COMMIT_MSG in tests/e2e/lib/fixture.ts, which the
      # smoke spec asserts gutter aria-labels for.
      msg =
        "Subject line under sixty-three chars\n\nBody paragraph that explains the why.\nMultiple lines so the gutter has a multi-line block.\n\n- bullet one\n- bullet two"

      assert [
               %{start_line: 1, end_line: 1},
               %{start_line: 3, end_line: 4},
               %{start_line: 6, end_line: 6},
               %{start_line: 7, end_line: 7}
             ] = ReviewState.blocks(msg)
    end

    test "numbered list (1. 2.) is also recognised as list" do
      msg = "Subject\n\n1. one\n2. two"

      assert [
               %{start_line: 1, end_line: 1},
               %{start_line: 3, end_line: 3, text: "1. one"},
               %{start_line: 4, end_line: 4, text: "2. two"}
             ] = ReviewState.blocks(msg)
    end

    test "mixed paragraph (some lines list-like, some not) stays as one block" do
      # Defensive: don't aggressively split if any line of the
      # paragraph is non-list — git commit body can include `-` at the
      # start of a sentence.
      msg = "Subject\n\nThis paragraph mentions - in passing.\nAnd continues."

      assert [
               %{start_line: 1, end_line: 1},
               %{start_line: 3, end_line: 4}
             ] = ReviewState.blocks(msg)
    end

    test "fenced code block is one block, fences included" do
      msg = "Subject\n\n```\nfn main() {\n    println!(\"hi\");\n}\n```\n\nTrailing."

      assert [
               %{start_line: 1, end_line: 1, text: "Subject"},
               %{start_line: 3, end_line: 7, text: code},
               %{start_line: 9, end_line: 9, text: "Trailing."}
             ] = ReviewState.blocks(msg)

      assert String.starts_with?(code, "```")
      assert String.ends_with?(code, "```")
      assert code =~ "fn main()"
    end

    test "tilde fence is also treated as one block" do
      msg = "Heading\n\n~~~elixir\n:ok\n~~~"

      assert [
               %{start_line: 1, end_line: 1},
               %{start_line: 3, end_line: 5}
             ] = ReviewState.blocks(msg)
    end
  end

  describe "approved_from_cache/3 — re-tick on mount from the per-branch cache" do
    alias Meerkat.ApprovalCache

    defp file(name, oid, status \\ :modified),
      do: %{file_name: name, effective_oid: oid, status: status}

    test "a modified file approved at its current OID is re-ticked" do
      cache = ApprovalCache.approve(%{}, "main", "a.rs", "oid1")

      assert ReviewState.approved_from_cache_for_test(cache, "main", [file("a.rs", "oid1")]) ==
               MapSet.new(["a.rs"])
    end

    test "an OID that no longer matches the cached one is not re-ticked" do
      cache = ApprovalCache.approve(%{}, "main", "a.rs", "oid1")

      assert ReviewState.approved_from_cache_for_test(cache, "main", [file("a.rs", "oid2")]) ==
               MapSet.new()
    end

    test "an approved deletion is re-ticked across rounds (regression)" do
      # Deletions once carried effective_oid "", which the cache gate
      # `oid != ""` rejected on both store and hydrate, dropping the tick.
      cache = ApprovalCache.approve(%{}, "main", "gone.rs", "headoid1")

      assert ReviewState.approved_from_cache_for_test(
               cache,
               "main",
               [file("gone.rs", "headoid1", :deleted)]
             ) == MapSet.new(["gone.rs"])
    end

    test "a deletion whose pre-image OID changed is not re-ticked" do
      cache = ApprovalCache.approve(%{}, "main", "gone.rs", "headoid1")

      assert ReviewState.approved_from_cache_for_test(
               cache,
               "main",
               [file("gone.rs", "headoid2", :deleted)]
             ) == MapSet.new()
    end

    test "an empty-OID file (failed staged-blob lookup) never matches a cached approval" do
      cache = ApprovalCache.approve(%{}, "main", "x.rs", "headoid1")

      assert ReviewState.approved_from_cache_for_test(cache, "main", [file("x.rs", "")]) ==
               MapSet.new()
    end
  end
end
