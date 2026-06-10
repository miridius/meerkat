defmodule Meerkat.CLITest do
  use ExUnit.Case, async: true

  import Meerkat.TestHelpers

  alias Meerkat.{ApprovalCache, CLI, ReviewLog}

  describe "parse_args/1" do
    test "defaults: no commit-msg / pr / positional, browser opens, port 0" do
      assert CLI.parse_args([]) == %{
               commit_msg_path: nil,
               positional: nil,
               pr: nil,
               no_open: false,
               port: 0
             }
    end

    test "--commit-msg threads through" do
      assert %{commit_msg_path: "/tmp/MSG"} = CLI.parse_args(["--commit-msg", "/tmp/MSG"])
    end

    test "--no-open is a boolean flag" do
      assert %{no_open: true} = CLI.parse_args(["--no-open"])
    end

    test "--port parses as integer" do
      assert %{port: 4321} = CLI.parse_args(["--port", "4321"])
    end

    test "positional arg is captured for ref/range parsing" do
      assert %{positional: "HEAD"} = CLI.parse_args(["HEAD"])
      assert %{positional: "main..feat"} = CLI.parse_args(["main..feat"])
      assert %{positional: "main...feat"} = CLI.parse_args(["main...feat"])
    end

    test "--pr threads through" do
      assert %{pr: "123"} = CLI.parse_args(["--pr", "123"])
    end

    test "all flags together" do
      assert CLI.parse_args(["--commit-msg", "/tmp/x", "--no-open", "--port", "0"]) == %{
               commit_msg_path: "/tmp/x",
               positional: nil,
               pr: nil,
               no_open: true,
               port: 0
             }
    end
  end

  describe "classify_for_auto_approve/5" do
    test "deleted + linguist-generated → :generated" do
      gen = %{"x.lock" => {:generated, true}}

      assert CLI.classify_for_auto_approve_for_test(
               %{file_name: "x.lock", status: :deleted},
               %{},
               "main",
               gen,
               %{}
             ) == :generated
    end

    test "deleted + not generated → :neither (a deleted source file still gets reviewed)" do
      gen = %{"x.rs" => {:generated, false}}

      assert CLI.classify_for_auto_approve_for_test(
               %{file_name: "x.rs", status: :deleted},
               %{},
               "main",
               gen,
               %{}
             ) == :neither
    end

    test "linguist-generated → :generated" do
      gen = %{"x.lock" => {:generated, true}}

      assert CLI.classify_for_auto_approve_for_test(%{file_name: "x.lock"}, %{}, "main", gen, %{}) ==
               :generated
    end

    test "approved at the current staged OID → :approved" do
      cache = ApprovalCache.approve(%{}, "main", "a.rs", "oid1")
      gen = %{"a.rs" => {:generated, false}}

      assert CLI.classify_for_auto_approve_for_test(
               %{file_name: "a.rs"},
               cache,
               "main",
               gen,
               %{"a.rs" => "oid1"}
             ) == :approved
    end

    test "approved at a different OID than the staged one → :neither" do
      cache = ApprovalCache.approve(%{}, "main", "a.rs", "oid1")
      gen = %{"a.rs" => {:generated, false}}

      assert CLI.classify_for_auto_approve_for_test(
               %{file_name: "a.rs"},
               cache,
               "main",
               gen,
               %{"a.rs" => "oid2"}
             ) == :neither
    end

    test "detached HEAD (nil branch) never matches an approval → :neither" do
      cache = ApprovalCache.approve(%{}, "main", "a.rs", "oid1")
      gen = %{"a.rs" => {:generated, false}}

      assert CLI.classify_for_auto_approve_for_test(
               %{file_name: "a.rs"},
               cache,
               nil,
               gen,
               %{"a.rs" => "oid1"}
             ) == :neither
    end
  end

  describe "decide_from_verdicts/2" do
    test "all linguist-generated → auto-approve (generated message)" do
      assert {:auto, msg} = CLI.decide_from_verdicts_for_test([:generated, :generated], 2)
      assert msg =~ "linguist-generated"
    end

    test "all already-approved → auto-approve (approved message, no generated mention)" do
      assert {:auto, msg} = CLI.decide_from_verdicts_for_test([:approved, :approved], 2)
      assert msg =~ "already approved"
      refute msg =~ "linguist-generated"
    end

    test "mix of approved + generated → auto-approve (combined message)" do
      assert {:auto, msg} = CLI.decide_from_verdicts_for_test([:approved, :generated], 2)
      assert msg =~ "already approved (1)"
      assert msg =~ "linguist-generated (1)"
    end

    test "any file still :neither → live review, never auto-approve" do
      # The safety guard: a commit carrying an unreviewed file must reach
      # the UI, even alongside approved/generated files.
      assert CLI.decide_from_verdicts_for_test([:approved, :neither], 2) == :live
      assert CLI.decide_from_verdicts_for_test([:generated, :neither], 2) == :live
      assert CLI.decide_from_verdicts_for_test([:neither], 1) == :live
    end
  end

  describe "args_error/2" do
    test "unrecognised options → rejection message" do
      assert CLI.args_error([], [{"--bogus", nil}]) =~ "unrecognised options: --bogus"
    end

    test "more than one positional → rejection message" do
      assert CLI.args_error(["a", "b"], []) =~ "at most one positional"
    end

    test "well-formed argv → nil" do
      assert CLI.args_error([], []) == nil
      assert CLI.args_error(["HEAD"], []) == nil
    end
  end

  describe "feedback_banner/2" do
    @path "/repo/.git/meerkat-precommit/reviews/20260601-main-files3.txt"

    test "attributes the count to the user, not the tool" do
      banner = CLI.feedback_banner_for_test(2, {:ok, @path})
      assert banner =~ "User left 2 comments total"
      # No "meerkat:" tool label — it would read as a third-party verdict
      # next to the first-party feedback framing. (The path legitimately
      # contains "meerkat-precommit".)
      refute banner =~ "meerkat:"
    end

    test "single comment is singular, plural otherwise" do
      single = CLI.feedback_banner_for_test(1, {:ok, @path})
      assert single =~ "User left 1 comment total"
      refute single =~ "comments total"

      assert CLI.feedback_banner_for_test(3, {:ok, @path}) =~ "User left 3 comments total"
    end

    test "nil count drops the number rather than printing a wrong 0" do
      banner = CLI.feedback_banner_for_test(nil, {:ok, @path})
      assert banner =~ "User left comments"
      refute banner =~ ~r/\d+ comment/
    end

    test "successful save names the recovery path" do
      assert CLI.feedback_banner_for_test(2, {:ok, @path}) =~ @path
    end

    test "failed save swaps in the couldn't-write wording and omits a path" do
      banner = CLI.feedback_banner_for_test(2, :error)
      assert banner =~ "could not be written to disk"
      refute banner =~ "saved to"
    end

    test "brackets with leading and trailing newlines so it survives at either truncation end" do
      banner = CLI.feedback_banner_for_test(1, {:ok, @path})
      assert String.starts_with?(banner, "\n")
      assert String.ends_with?(banner, "\n")
    end
  end

  describe "pause_banner/2" do
    @url "http://127.0.0.1:54321/"

    test "commit-msg hook flow gets git-commit wording and landed semantics" do
      banner = CLI.pause_banner_for_test({:staged, "/tmp/COMMIT_MSG"}, @url)
      assert banner =~ "Paused for human review at #{@url}"
      assert banner =~ "this `git commit` process blocks"
      assert banner =~ "Exit 0 = approved & landed"
    end

    test "ad-hoc targets get generic meerkat wording — nothing lands on approve" do
      for target <- [
            {:staged, nil},
            {:single_ref, "HEAD"},
            {:range, "a", "b", :two_dot},
            {:pr, "1"}
          ] do
        banner = CLI.pause_banner_for_test(target, @url)
        assert banner =~ "this `meerkat` process blocks"
        assert banner =~ "Exit 0 = approved,"
        refute banner =~ "git commit"
        refute banner =~ "landed"
      end
    end

    test "core agent instructions survive in every variant" do
      for target <- [{:staged, "/tmp/MSG"}, {:pr, "1"}] do
        banner = CLI.pause_banner_for_test(target, @url)
        assert banner =~ "do NOT poll, sleep, or schedule wake-ups"
        assert banner =~ "exit 1 = changes requested"
        assert banner =~ "read the\nfull process output afterwards"
      end
    end
  end

  describe "feedback_file_path/1" do
    test "derives the .txt sibling of the review-log file, preserving the per-review stem" do
      log = %ReviewLog{path: "/r/.git/meerkat-precommit/reviews/20260601120000-main-files3.json"}

      assert CLI.feedback_file_path_for_test(log) ==
               "/r/.git/meerkat-precommit/reviews/20260601120000-main-files3.txt"
    end

    test "distinct reviews get distinct feedback paths — no fixed-name clobber" do
      a = %ReviewLog{path: "/r/reviews/20260601120000-main-files3.json"}
      b = %ReviewLog{path: "/r/reviews/20260601120500-feature-x-files1.json"}

      refute CLI.feedback_file_path_for_test(a) == CLI.feedback_file_path_for_test(b)
    end
  end

  describe "comment_count/1" do
    test "a missing/dead review server yields nil rather than raising" do
      id = "no-live-review-#{System.unique_integer([:positive])}"
      assert CLI.comment_count_for_test(id) == nil
    end
  end

  describe "write_feedback/3" do
    test "empty payload writes nothing — no banner, no file lookup" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert CLI.write_feedback_for_test("", "any-review-id", "/tmp/unused.txt") == :ok
        end)

      assert output == ""
    end

    test "writes the recovery file and brackets the payload with the banner" do
      path = Path.join(make_tmp_repo("meerkat-cli-fb"), "fb.txt")

      out =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert CLI.write_feedback_for_test("PAYLOAD-BODY", "no-live-review", path) == :ok
        end)

      assert File.read!(path) == "PAYLOAD-BODY"
      assert out =~ "PAYLOAD-BODY"
      # Banner appears top and bottom so it survives a head/tail truncation.
      assert length(Regex.scan(~r/full feedback saved to/, out)) == 2
    end

    test "an unwritable path breadcrumbs the reason, degrades the banner, stays non-fatal" do
      bad = "/no-such-dir-#{System.unique_integer([:positive])}/fb.txt"

      out =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert CLI.write_feedback_for_test("PAYLOAD-BODY", "no-live-review", bad) == :ok
        end)

      refute File.exists?(bad)
      assert out =~ "couldn't save full feedback to #{bad}"
      assert out =~ "full feedback could not be written to disk"
      assert out =~ "PAYLOAD-BODY"
    end
  end
end
