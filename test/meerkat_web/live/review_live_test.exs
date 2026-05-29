defmodule MeerkatWeb.ReviewLiveTest do
  # `MeerkatWeb.ReviewLive` is 2k+ lines of LV behaviour. This file
  # currently pins ONLY the bits the rest of the suite doesn't reach —
  # the pure synthesised-label helpers (`label_for_github_for_test/2`,
  # `render_comment_body_for_test/2`) that render empty-body revert
  # comments on three distinct render surfaces.
  #
  # The same wording lives in `Meerkat.Feedback.label_body` (covered
  # by `feedback_test.exs`); the duplication is a known DRY smell.
  # These tests pin the OTHER two copies so a future wording change
  # that updates only one site fails CI instead of silently diverging
  # the three surfaces.
  use ExUnit.Case, async: true

  alias MeerkatWeb.ReviewLive

  describe "label_for_github (GitHub PR PENDING-review body)" do
    test "empty-body revert renders the subject-less `restore from HEAD` label" do
      assert ReviewLive.label_for_github_for_test(:revert, "") ==
               "**restore from HEAD**"

      assert ReviewLive.label_for_github_for_test("revert", "") ==
               "**restore from HEAD**"

      # Whitespace-only body trips the same branch.
      assert ReviewLive.label_for_github_for_test(:revert, "   \n  ") ==
               "**restore from HEAD**"
    end

    test "revert with prose body still renders the type prefix" do
      assert ReviewLive.label_for_github_for_test(:revert, "needs proper fix") ==
               "**revert:** needs proper fix"
    end

    test "non-revert empty body renders the type prefix" do
      assert ReviewLive.label_for_github_for_test(:issue, "") == "**issue:** "
    end

    test "missing finding-type falls back to bare body" do
      assert ReviewLive.label_for_github_for_test("", "just text") == "just text"
      assert ReviewLive.label_for_github_for_test(nil, "just text") == "just text"
    end
  end

  describe "render_comment_body (in-tab Svelte InlineComment card)" do
    test "empty-body revert renders the synthesised HTML sentence" do
      assert ReviewLive.render_comment_body_for_test("", :revert) ==
               "<p><strong>Restore from HEAD.</strong></p>"

      assert ReviewLive.render_comment_body_for_test("", "revert") ==
               "<p><strong>Restore from HEAD.</strong></p>"

      assert ReviewLive.render_comment_body_for_test(nil, :revert) ==
               "<p><strong>Restore from HEAD.</strong></p>"
    end

    test "revert with prose body falls through to markdown rendering" do
      html = ReviewLive.render_comment_body_for_test("needs **proper** fix", :revert)
      assert html =~ "<strong>proper</strong>"
      # Synthesised label must not coexist with the prose render.
      refute html =~ "Restore from HEAD"
    end

    test "non-revert with empty body renders empty markdown" do
      assert ReviewLive.render_comment_body_for_test("", :issue) == ""
    end
  end
end
