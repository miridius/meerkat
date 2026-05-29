defmodule Meerkat.CLITest do
  use ExUnit.Case, async: true

  alias Meerkat.{ApprovalCache, CLI}

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
end
