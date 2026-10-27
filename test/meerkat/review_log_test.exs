defmodule Meerkat.ReviewLogTest do
  use ExUnit.Case, async: true

  alias Meerkat.ReviewLog

  describe "start/2" do
    test "a detached HEAD logs no branch but reads approvals under its key" do
      dir = Meerkat.TestHelpers.make_git_repo("meerkat-review-log")
      on_exit(fn -> File.rm_rf!(dir) end)
      key = "detached HEAD (.git)"
      # A file with no staged OID never counts as approved, even against
      # a cache entry holding an empty OID.
      approve = fn cache ->
        cache
        |> Meerkat.ApprovalCache.approve(key, "a.rs", "oid1")
        |> Meerkat.ApprovalCache.approve(key, "b.rs", "")
      end

      {:ok, _} = Meerkat.ApprovalCache.modify(Meerkat.ApprovalCache.path_for(dir), approve)

      state = %Meerkat.ReviewState{
        files: [
          %{file_name: "a.rs", effective_oid: "oid1"},
          %{file_name: "b.rs", effective_oid: ""}
        ],
        approval_key: key
      }

      %ReviewLog{record: record} = ReviewLog.start(dir, state)
      assert record.branch == nil

      assert [%{file_name: "a.rs", was_approved: true}, %{file_name: "b.rs", was_approved: false}] =
               record.files
    end

    test "starting a log prunes the approvals of a deleted branch, then reads the pruned cache" do
      dir = Meerkat.TestHelpers.make_git_repo("meerkat-review-log-prune")
      on_exit(fn -> File.rm_rf!(dir) end)
      Meerkat.TestHelpers.git(dir, ["symbolic-ref", "HEAD", "refs/heads/main"])

      Meerkat.TestHelpers.git(dir, [
        "-c",
        "user.email=t@t",
        "-c",
        "user.name=t",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "seed"
      ])

      approve = fn cache ->
        Enum.reduce(
          ["main", "gone"],
          cache,
          &Meerkat.ApprovalCache.approve(&2, &1, "a.rs", "oid1")
        )
      end

      {:ok, _} = Meerkat.ApprovalCache.modify(Meerkat.ApprovalCache.path_for(dir), approve)

      state = %Meerkat.ReviewState{
        files: [%{file_name: "a.rs", effective_oid: "oid1"}],
        approval_key: "gone"
      }

      %ReviewLog{record: record} = ReviewLog.start(dir, state)
      assert [%{file_name: "a.rs", was_approved: false}] = record.files
      assert dir |> Meerkat.ApprovalCache.load_for() |> Map.keys() == ["main"]
    end
  end

  describe "slugify_branch/1" do
    test "nil + empty string fall back to no-branch" do
      assert ReviewLog.slugify_branch(nil) == "no-branch"
      assert ReviewLog.slugify_branch("") == "no-branch"
    end

    test "passes safe chars through unchanged" do
      assert ReviewLog.slugify_branch("main") == "main"
      assert ReviewLog.slugify_branch("v1.2.3") == "v1.2.3"
      assert ReviewLog.slugify_branch("feat_new-thing") == "feat_new-thing"
      assert ReviewLog.slugify_branch("A-B.C_d.0") == "A-B.C_d.0"
    end

    test "replaces unsafe chars with `-`" do
      assert ReviewLog.slugify_branch("feat/new") == "feat-new"
      assert ReviewLog.slugify_branch("user@host") == "user-host"
      assert ReviewLog.slugify_branch("a b c") == "a-b-c"
    end

    test "truncates to 40 chars" do
      branch = String.duplicate("x", 100)
      slug = ReviewLog.slugify_branch(branch)
      assert String.length(slug) == 40
      assert slug == String.duplicate("x", 40)
    end

    test "Unicode chars are replaced (multi-byte → multi-`-`)" do
      # `é` is two UTF-8 bytes; the regex replaces each non-ASCII
      # byte separately. Document the actual behaviour so a future
      # refactor that switches to grapheme-aware replacement is a
      # deliberate decision.
      assert ReviewLog.slugify_branch("féature") == "f--ature"
    end

    test "control characters are sanitised" do
      assert ReviewLog.slugify_branch("feat\nfoo") == "feat-foo"
      assert ReviewLog.slugify_branch("feat\tfoo") == "feat-foo"
    end
  end

  describe "file_tag/1" do
    test "empty list" do
      assert ReviewLog.file_tag([]) == "empty"
    end

    test "non-empty list — `files<n>`" do
      assert ReviewLog.file_tag([%{}]) == "files1"
      assert ReviewLog.file_tag(List.duplicate(%{}, 5)) == "files5"
      assert ReviewLog.file_tag(List.duplicate(%{}, 99)) == "files99"
    end
  end
end
