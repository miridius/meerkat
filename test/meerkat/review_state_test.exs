defmodule Meerkat.ReviewStateTest do
  # --- Documented surviving mutants (CLAUDE.md, Mutation testing) ---
  #
  # Equivalent (no input distinguishes mutant from original):
  # * Deleting `split_off_fenced_code/3`'s `[] -> out` case clause:
  #   the empty chunk then reaches `chunk_paragraphs/1`, which turns
  #   `[]` into no blocks.

  # Not async: the `from_target/2` tests put a `gh` stub on PATH, which
  # is process-global.
  use ExUnit.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, isolate_git_config: 0, make_tmp_repo: 1, stage: 3]

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

    test "a blank line inside a fence stays in the single code block" do
      # An unrecognised fence would let the prose splitter break this on
      # the blank line; one code block proves the fence held across it.
      assert [%{start_line: 1, end_line: 5, text: "```\na\n\nb\n```"}] =
               ReviewState.blocks("```\na\n\nb\n```")
    end

    test "a whitespace-only separator line produces no block of its own" do
      # The separator is `" "`, not the empty string, so it is dropped by
      # the all-blank check rather than the leading-empty-line check.
      assert [
               %{start_line: 1, end_line: 1, text: "Subject"},
               %{start_line: 3, end_line: 3, text: "Body"}
             ] = ReviewState.blocks("Subject\n \nBody")
    end
  end

  describe "from_target/2 — real git, `gh` stubbed on PATH" do
    setup do
      isolate_git_config()
      base = make_tmp_repo("meerkat-review-state")
      File.rm_rf!(Path.join(base, ".git"))
      old_path = System.fetch_env!("PATH")

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(base)
      end)

      {:ok, base: base}
    end

    test "'#' comment lines in the commit-msg file are stripped, the message kept", %{base: base} do
      repo = Path.join(base, "repo")
      File.mkdir_p!(repo)
      init_repo(repo)
      git(repo, ["commit", "--allow-empty", "-qm", "initial"])
      stage(repo, "a.rs", "fn a() {}\n")

      commit_msg = Path.join(base, "COMMIT_MSG")

      File.write!(commit_msg, """
      Subject

      Real body line.

      # Please enter the commit message for your changes. Lines starting
      # with '#' will be ignored, and an empty message aborts the commit.
      # On branch main
      """)

      # The branch has no PR, as `gh` reports it.
      stub_gh(base, ~s(echo 'no pull requests found for branch "main"' >&2; exit 1))

      assert {:ok, state} = ReviewState.from_target({:staged, commit_msg}, repo)
      assert state.precommit?
      assert state.commit_message == "Subject\n\nReal body line."

      assert [%{start_line: 1, text: "Subject"}, %{start_line: 3, text: "Real body line."}] =
               state.commit_message_blocks
    end

    test "--pr reviews the PR head against its base, with the PR's metadata", %{base: base} do
      # Mirrors how GitHub publishes a PR: a remote holding the base
      # branch and `refs/pull/<N>/head`, cloned locally.
      remote = Path.join(base, "remote.git")
      staging = Path.join(base, "staging")
      clone = Path.join(base, "clone")
      Enum.each([remote, staging, clone], &File.mkdir_p!/1)

      git(remote, ["init", "-q", "--bare", "-b", "main"])
      init_repo(staging)
      stage(staging, "base.txt", "shared base content\n")
      git(staging, ["commit", "-qm", "Initial base"])
      git(staging, ["remote", "add", "origin", remote])
      git(staging, ["push", "-q", "origin", "main"])
      stage(staging, "feature.rs", "fn feature() {}\n")
      git(staging, ["commit", "-qm", "Add feature"])
      git(staging, ["push", "-q", "origin", "HEAD:refs/pull/123/head"])
      git(clone, ["clone", "-q", remote, "."])

      pr = %{
        number: 123,
        baseRefName: "main",
        headRefName: "feat/the-feature",
        title: "Feature: a wonderful feature",
        body: "This PR adds the wonderful feature, see linked issue.",
        url: "https://github.com/example/example/pull/123"
      }

      stub_gh(base, """
      if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
        cat <<'EOF_JSON'
      #{Jason.encode!(pr)}
      EOF_JSON
        exit 0
      fi
      echo "gh stub: unsupported invocation: $*" >&2
      exit 1
      """)

      assert {:ok, state} = ReviewState.from_target({:pr, "123"}, clone)
      assert Enum.map(state.files, &{&1.file_name, &1.status}) == [{"feature.rs", :added}]
      assert state.pr == %{number: 123, title: pr.title, url: pr.url}
      assert state.commit_message == pr.body
      assert {state.head_branch, state.base_branch} == {"feat/the-feature", "main"}
      refute state.precommit?
    end

    defp init_repo(dir) do
      git(dir, ["init", "-q", "-b", "main"])
      git(dir, ["config", "user.email", "t@t.t"])
      git(dir, ["config", "user.name", "t"])
    end

    defp stub_gh(dir, body) do
      bin = Path.join(dir, "gh-stub")
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "gh"), "#!/bin/sh\n#{body}")
      File.chmod!(Path.join(bin, "gh"), 0o755)
      System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
    end
  end

  describe "base_branch/2 — PR base wins, else the range fallback" do
    test "a PR with a usable base_ref overrides the fallback" do
      assert ReviewState.base_branch_for_test(%{base_ref: "origin/main"}, "HEAD~1") ==
               "origin/main"
    end

    test "a blank base_ref falls back to the range base" do
      assert ReviewState.base_branch_for_test(%{base_ref: ""}, "HEAD~1") == "HEAD~1"
    end

    test "no PR falls back to the range base" do
      assert ReviewState.base_branch_for_test(nil, "HEAD~1") == "HEAD~1"
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

    test "an empty OID is rejected even if the cache holds an approval AT \"\"" do
      # A corrupt/hand-edited cache could hold an entry at "", so the
      # `oid != ""` guard has to reject the sentinel on its own.
      cache = ApprovalCache.approve(%{}, "main", "x.rs", "")

      assert ReviewState.approved_from_cache_for_test(cache, "main", [file("x.rs", "")]) ==
               MapSet.new()
    end
  end

  describe "from_target/2 — staged review mid-rebase (real git fixture)" do
    import Meerkat.TestHelpers, only: [split_approved_commit_mid_rebase: 1, stage: 3]

    test "approved files come back ticked beside unseen changes" do
      dir = split_approved_commit_mid_rebase("meerkat-state-rebase")
      stage(dir, "one.rs", "fn one() -> i32 { 1 }\n")
      stage(dir, "two.rs", "fn two() -> i32 { 21 }\n")

      assert {:ok, state} = ReviewState.from_target({:staged, nil}, dir)
      assert state.head_branch == "feature"
      assert state.approved_file_names == MapSet.new(["one.rs"])
    end
  end
end
