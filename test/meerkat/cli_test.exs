defmodule Meerkat.CLITest do
  use ExUnit.Case, async: true

  import Meerkat.TestHelpers

  alias Meerkat.{ApprovalCache, CLI, PendingAnswers, ReviewLog}

  # Strip git's discovery env vars before shelling out (same set as
  # `Meerkat.Git`): under a git hook these point at the parent repo and
  # would override `cd: dir` in the pending-answers-gate fixture's `git
  # init`.
  @git_discovery_overrides Enum.map(
                             ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
                                GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
                                GIT_NAMESPACE),
                             &{&1, nil}
                           )

  defp git(dir, args) do
    {out, code} =
      System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: @git_discovery_overrides)

    if code != 0, do: flunk("git #{Enum.join(args, " ")} failed: #{out}")
    String.trim(out)
  end

  defp write_pending_answers(repo) do
    path = PendingAnswers.path_for(repo)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "createdAt" => "2026-05-14T00:00:00Z",
        "answers" => [
          %{"location" => "src/foo.rs:42", "question" => "why this?", "answer" => "because"}
        ]
      })
    )

    path
  end

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

    test "deleted + not generated + not approved → :neither (gets reviewed)" do
      gen = %{"x.rs" => {:generated, false}}

      assert CLI.classify_for_auto_approve_for_test(
               %{file_name: "x.rs", status: :deleted},
               %{},
               "main",
               gen,
               %{}
             ) == :neither
    end

    test "deleted + approved at its HEAD pre-image OID → :approved" do
      cache = ApprovalCache.approve(%{}, "main", "x.rs", "headoid1")
      gen = %{"x.rs" => {:generated, false}}

      assert CLI.classify_for_auto_approve_for_test(
               %{file_name: "x.rs", status: :deleted},
               cache,
               "main",
               gen,
               %{"x.rs" => "headoid1"}
             ) == :approved
    end

    test "deleted + approved at a different pre-image OID (deleted content changed) → :neither" do
      cache = ApprovalCache.approve(%{}, "main", "x.rs", "headoid1")
      gen = %{"x.rs" => {:generated, false}}

      assert CLI.classify_for_auto_approve_for_test(
               %{file_name: "x.rs", status: :deleted},
               cache,
               "main",
               gen,
               %{"x.rs" => "headoid2"}
             ) == :neither
    end

    test "deleted + approved but detached HEAD (nil branch) → :neither" do
      cache = ApprovalCache.approve(%{}, "main", "x.rs", "headoid1")
      gen = %{"x.rs" => {:generated, false}}

      assert CLI.classify_for_auto_approve_for_test(
               %{file_name: "x.rs", status: :deleted},
               cache,
               nil,
               gen,
               %{"x.rs" => "headoid1"}
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

  describe "feedback_banner/3" do
    @path "/repo/.git/meerkat-precommit/reviews/20260601-main-files3.txt"

    test "states the verdict — approved vs requested changes" do
      assert CLI.feedback_banner_for_test(:reject, 2, {:ok, @path}) =~ "User requested changes"

      assert CLI.feedback_banner_for_test(:approve_with_feedback, 2, {:ok, @path}) =~
               "User approved your commit"
    end

    test "a timed-out review says the commit went in unread" do
      banner = CLI.feedback_banner_for_test(:timeout, 2, {:ok, @path})
      assert banner =~ "Review timed out, commit auto-approved unread"
      refute banner =~ "User approved"
    end

    test "is user-attributed, not tool-attributed" do
      banner = CLI.feedback_banner_for_test(:reject, 2, {:ok, @path})
      # No "meerkat:" tool label — it would read as a third-party verdict
      # next to the first-party feedback framing. (The path legitimately
      # contains "meerkat-precommit".)
      refute banner =~ "meerkat:"
    end

    test "single comment is singular, plural otherwise" do
      single = CLI.feedback_banner_for_test(:reject, 1, {:ok, @path})
      assert single =~ "1 comment "
      refute single =~ "1 comments"

      assert CLI.feedback_banner_for_test(:reject, 3, {:ok, @path}) =~ "3 comments"
    end

    test "nil or zero count drops the number rather than printing a wrong 0" do
      for count <- [nil, 0] do
        banner = CLI.feedback_banner_for_test(:reject, count, {:ok, @path})
        assert banner =~ "User requested changes"
        refute banner =~ ~r/\d+ comment/
      end
    end

    test "successful save names the recovery path" do
      assert CLI.feedback_banner_for_test(:reject, 2, {:ok, @path}) =~ @path
    end

    test "failed save swaps in the couldn't-write wording and omits a path" do
      banner = CLI.feedback_banner_for_test(:reject, 2, :error)
      assert banner =~ "could not be written to disk"
      refute banner =~ "saved to"
    end

    test "no recovery file (empty payload) still states the verdict, omits the file clause" do
      banner = CLI.feedback_banner_for_test(:reject, 0, :none)
      assert banner =~ "User requested changes"
      refute banner =~ "feedback"
    end

    test "brackets with leading and trailing newlines so it survives at either truncation end" do
      banner = CLI.feedback_banner_for_test(:reject, 1, {:ok, @path})
      assert String.starts_with?(banner, "\n")
      assert String.ends_with?(banner, "\n")
    end
  end

  describe "limit_phrase/1" do
    test "a whole number of minutes reads as minutes" do
      assert CLI.limit_phrase_for_test(30 * 60 * 1000) == "30 minutes"
      assert CLI.limit_phrase_for_test(60_000) == "1 minute"
    end

    test "a limit that is not a whole number of minutes reads as seconds" do
      assert CLI.limit_phrase_for_test(90_000) == "90 seconds"
      assert CLI.limit_phrase_for_test(45_000) == "45 seconds"
      assert CLI.limit_phrase_for_test(1000) == "1 second"
    end
  end

  describe "pause_banner/2" do
    @url "http://127.0.0.1:54321/"

    test "commit-msg hook flow names the git-commit process" do
      banner = CLI.pause_banner_for_test({:staged, "/tmp/COMMIT_MSG"}, @url)
      assert banner =~ "Paused for human review at #{@url}"
      assert banner =~ "this `git commit` process blocks"
    end

    test "ad-hoc targets name the meerkat process" do
      for target <- [
            {:staged, nil},
            {:single_ref, "HEAD"},
            {:range, "a", "b", :two_dot},
            {:pr, "1"}
          ] do
        banner = CLI.pause_banner_for_test(target, @url)
        assert banner =~ "this `meerkat` process blocks"
        refute banner =~ "git commit"
      end
    end

    test "names no exit codes — a tailed log can't see the exit status" do
      for target <- [{:staged, "/tmp/MSG"}, {:pr, "1"}] do
        banner = CLI.pause_banner_for_test(target, @url)
        refute banner =~ ~r/exit \d/i
      end
    end

    test "core agent instructions survive in every variant" do
      for target <- [{:staged, "/tmp/MSG"}, {:pr, "1"}] do
        banner = CLI.pause_banner_for_test(target, @url)
        flat = String.replace(banner, ~r/\s+/, " ")
        assert flat =~ "do NOT poll, sleep, or schedule wake-ups"
        assert flat =~ "approved or requested changes"
        assert flat =~ "not a `tail`/`head` of it"
      end
    end
  end

  describe "repo_path/0" do
    # async: true is safe — these are the only tests touching
    # MEERKAT_PWD, and the var is restored before exit.
    test "prefers MEERKAT_PWD over the BEAM's cwd" do
      prev = System.get_env("MEERKAT_PWD")

      try do
        System.put_env("MEERKAT_PWD", "/somewhere/else")
        assert CLI.repo_path_for_test() == "/somewhere/else"

        System.delete_env("MEERKAT_PWD")
        assert CLI.repo_path_for_test() == File.cwd!()
      after
        if prev, do: System.put_env("MEERKAT_PWD", prev), else: System.delete_env("MEERKAT_PWD")
      end
    end
  end

  describe "endpoint_config/1" do
    test "non-dev builds force off the dev conveniences" do
      # @env is :test, which takes the prod (non-dev) branch.
      config = CLI.endpoint_config_for_test(4321)

      assert config[:code_reloader] == false
      assert config[:watchers] == []
      assert config[:server] == true
      assert config[:http] == [ip: {127, 0, 0, 1}, port: 4321]
      assert is_binary(config[:secret_key_base])
    end
  end

  describe "secret_key_base/0" do
    test "uses SECRET_KEY_BASE when set, random bytes otherwise" do
      prev = System.get_env("SECRET_KEY_BASE")

      try do
        System.put_env("SECRET_KEY_BASE", "from-env")
        assert CLI.secret_key_base_for_test() == "from-env"

        System.delete_env("SECRET_KEY_BASE")
        generated = CLI.secret_key_base_for_test()
        assert generated != "from-env"
        assert byte_size(Base.decode64!(generated)) == 48
      after
        if prev,
          do: System.put_env("SECRET_KEY_BASE", prev),
          else: System.delete_env("SECRET_KEY_BASE")
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

  describe "write_feedback/4" do
    test "empty payload still announces the verdict, writes no file" do
      # Unique path so a leftover file from another run can't fail the
      # "writes no file" assertion below.
      unwritten =
        Path.join(
          System.tmp_dir!(),
          "meerkat-cli-unwritten-#{System.unique_integer([:positive])}.txt"
        )

      out =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert CLI.write_feedback_for_test(:reject, "", "no-live-review", unwritten) == :ok
        end)

      assert out =~ "User requested changes"
      refute out =~ "saved to"
      refute File.exists?(unwritten)
    end

    test "writes the recovery file and brackets the payload with the verdict banner" do
      path = Path.join(make_tmp_repo("meerkat-cli-fb"), "fb.txt")

      out =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert CLI.write_feedback_for_test(:reject, "PAYLOAD-BODY", "no-live-review", path) ==
                   :ok
        end)

      assert File.read!(path) == "PAYLOAD-BODY"
      assert out =~ "PAYLOAD-BODY"
      # Verdict + path appear top and bottom so they survive a head/tail truncation.
      assert length(Regex.scan(~r/User requested changes/, out)) == 2
      assert length(Regex.scan(~r/full feedback saved to/, out)) == 2
    end

    test "an unwritable path breadcrumbs the reason, degrades the banner, stays non-fatal" do
      bad = "/no-such-dir-#{System.unique_integer([:positive])}/fb.txt"

      out =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert CLI.write_feedback_for_test(:reject, "PAYLOAD-BODY", "no-live-review", bad) ==
                   :ok
        end)

      refute File.exists?(bad)
      assert out =~ "couldn't save full feedback to #{bad}"
      assert out =~ "full feedback could not be written to disk"
      assert out =~ "PAYLOAD-BODY"
    end

    test "a timed-out review's comments reach the agent under the unread banner" do
      path = Path.join(make_tmp_repo("meerkat-cli-timeout-fb"), "fb.txt")

      out =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert CLI.write_feedback_for_test(:timeout, "PAYLOAD-BODY", "no-live-review", path) ==
                   :ok
        end)

      assert File.read!(path) == "PAYLOAD-BODY"
      assert out =~ "PAYLOAD-BODY"
      assert length(Regex.scan(~r/Review timed out, commit auto-approved unread/, out)) == 2
      refute out =~ "User approved"
    end
  end

  describe "auto_approve_decision/2 — pending-answers gate (real git fixture)" do
    # Real-git fixture (not async: each test owns a tmp repo and shells
    # out to `git`). A prior review's **question**-type comments leave a
    # pending-answers.json in the worktree's gitdir; the staged
    # auto-approve fast path must NEVER fire while it exists, or the
    # agent's answers get silently discarded (the "meerkat drops answers
    # on a clean tree" bug). The reviewer sees them via a live review
    # instead, and only a terminal decision clears the file.
    setup do
      dir =
        Path.join(System.tmp_dir!(), "meerkat-cli-gate-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      git(dir, ["init", "-q", "-b", "main"])
      git(dir, ["config", "user.email", "t@t.t"])
      git(dir, ["config", "user.name", "t"])
      File.write!(Path.join(dir, "seed.rs"), "fn seed() {}\n")
      git(dir, ["add", "seed.rs"])
      git(dir, ["commit", "-qm", "seed"])
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "empty staged diff + no pending answers → auto-approves (fast path unchanged)",
         %{dir: dir} do
      # The smoke-test path in scripts/install.sh and message-only
      # `git commit --amend` rely on this still skipping the UI.
      # Exact message: a mutation that drops the empty-staged clause
      # would surface the vacuous all-generated wording instead.
      assert {:auto, "meerkat: no staged file changes — auto-approving.\n"} =
               CLI.auto_approve_decision_for_test(dir)
    end

    test "staged unapproved file + no pending answers → live review (safety invariant)", %{
      dir: dir
    } do
      # The unreviewed-file guard: a staged file that is neither
      # generated nor already-approved must reach the UI even with no
      # pending answers.
      File.write!(Path.join(dir, "a.rs"), "fn a() {}\n")
      git(dir, ["add", "a.rs"])
      assert CLI.auto_approve_decision_for_test(dir) == :live
    end

    test "empty staged diff + pending answers → live review, never auto-approve", %{dir: dir} do
      write_pending_answers(dir)
      assert CLI.auto_approve_decision_for_test(dir) == :live
    end

    test "auto_approve_decision/2 with pending answers leaves the file in place", %{dir: dir} do
      path = write_pending_answers(dir)
      assert CLI.auto_approve_decision_for_test(dir) == :live
      assert File.exists?(path)
    end

    test "staged file + pending answers → live review even when every file is approved", %{
      dir: dir
    } do
      # A file already approved at its staged OID would otherwise hit
      # the all-approved auto-approve branch — with answers pending the
      # gate must block that too, or they'd be discarded mid-iteration.
      File.write!(Path.join(dir, "a.rs"), "fn a() {}\n")
      git(dir, ["add", "a.rs"])
      oid = git(dir, ["rev-parse", ":a.rs"])

      with path <- ApprovalCache.path_for(dir) do
        {:ok, _} = ApprovalCache.modify(path, &ApprovalCache.approve(&1, "main", "a.rs", oid))
      end

      write_pending_answers(dir)
      assert CLI.auto_approve_decision_for_test(dir) == :live
    end
  end
end
