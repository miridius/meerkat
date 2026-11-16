defmodule Meerkat.ReviewLogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Meerkat.TestHelpers, only: [git: 2, tmp_path: 1]

  alias Meerkat.{ApprovalCache, ReviewLog, ReviewState}

  setup do
    repo = tmp_path("meerkat-review-log")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(repo) end)
    git(repo, ["init", "-q"])
    %{repo: repo}
  end

  defp read_log(%ReviewLog{path: path}), do: path |> File.read!() |> Jason.decode!()

  describe "start/2" do
    test "records each file's OID and whether the approval cache already approved it", %{
      repo: repo
    } do
      # Starting a log prunes the approvals of a branch that does not exist.
      git(repo, ["symbolic-ref", "HEAD", "refs/heads/main"])
      Meerkat.TestHelpers.commit(repo, "seed")

      :ok =
        ApprovalCache.save(
          %{"main" => %{"approved.ex" => ["oid-a"]}},
          ApprovalCache.path_for(repo)
        )

      state = %ReviewState{
        head_branch: "main",
        approval_key: "main",
        files: [
          %{file_name: "approved.ex", effective_oid: "oid-a"},
          %{file_name: "changed.ex", effective_oid: "oid-b"},
          %{file_name: "unstaged.ex"}
        ]
      }

      log = ReviewLog.start(repo, state)

      assert Path.basename(log.path) =~ ~r/^\d{14}-main-files3\.json$/

      assert %{"decision" => "in-progress", "finished_at" => nil, "files" => files} =
               read_log(log)

      assert files == [
               %{
                 "file_name" => "approved.ex",
                 "effective_oid" => "oid-a",
                 "was_approved" => true
               },
               %{
                 "file_name" => "changed.ex",
                 "effective_oid" => "oid-b",
                 "was_approved" => false
               },
               %{"file_name" => "unstaged.ex", "effective_oid" => "", "was_approved" => false}
             ]
    end

    test "marks no file approved when the review has no branch", %{repo: repo} do
      :ok =
        ApprovalCache.save(%{"main" => %{"a.ex" => ["oid-a"]}}, ApprovalCache.path_for(repo))

      log =
        ReviewLog.start(repo, %ReviewState{files: [%{file_name: "a.ex", effective_oid: "oid-a"}]})

      assert [%{"was_approved" => false}] = read_log(log)["files"]
    end

    test "warns and still returns the log when the record cannot be encoded", %{repo: repo} do
      state = %ReviewState{commit_message: <<0xFF>>}

      stderr = capture_io(:stderr, fn -> send(self(), {:log, ReviewLog.start(repo, state)}) end)

      assert_received {:log, %ReviewLog{} = log}
      refute File.exists?(log.path)
      assert stderr =~ ~r/\Ameerkat: warning — couldn't encode review log: %Jason\.EncodeError/
    end
  end

  describe "finalize/3" do
    test "rewrites the log with the decision, finish time and feedback", %{repo: repo} do
      log = ReviewLog.start(repo, %ReviewState{head_branch: "main"})

      updated = ReviewLog.finalize(log, :rejected, "fix the tests")

      assert updated.path == log.path
      assert updated.record.decision == "rejected"
      on_disk = read_log(updated)
      assert on_disk["decision"] == "rejected"
      assert on_disk["rendered_feedback"] == "fix the tests"
      assert {:ok, _, 0} = DateTime.from_iso8601(on_disk["finished_at"])
      assert on_disk["started_at"] == log.record.started_at
    end

    test "records empty feedback as null", %{repo: repo} do
      log = ReviewLog.start(repo, %ReviewState{})

      assert %{"decision" => "approved", "rendered_feedback" => nil} =
               log |> ReviewLog.finalize(:approved, "") |> read_log()
    end

    test "warns and returns the updated log when the file cannot be written", %{repo: repo} do
      blocker = Path.join(repo, "not-a-dir")
      File.write!(blocker, "")
      log = %ReviewLog{path: Path.join(blocker, "review.json"), record: %{}}

      stderr =
        capture_io(:stderr, fn -> send(self(), {:log, ReviewLog.finalize(log, :approved, "")}) end)

      assert_received {:log, %ReviewLog{record: %{decision: "approved"}}}

      warning = "meerkat: warning — couldn't write review log to #{log.path}: :enotdir"
      assert warning in String.split(stderr, "\n")
    end
  end

  describe "start/2 and the approval cache" do
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
      Meerkat.TestHelpers.commit(dir, "seed")

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
