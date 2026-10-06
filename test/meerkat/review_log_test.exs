defmodule Meerkat.ReviewLogTest do
  use ExUnit.Case, async: true

  alias Meerkat.ReviewLog

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
