defmodule Meerkat.GitIntegrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias Meerkat.Git

  import Meerkat.TestHelpers, only: [stage: 3, intercept_git: 3]

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-git-integration")
    git(dir, ["init", "-q", "--initial-branch=main"])
    git(dir, ["config", "user.email", "t@t.t"])
    git(dir, ["config", "user.name", "t"])
    git(dir, ["config", "core.hooksPath", "/dev/null"])
    git(dir, ["config", "diff.renames", "true"])
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "Git helpers isolate global signing and diff-prefix settings", %{dir: dir} do
    config = Path.join(dir, "global.gitconfig")
    File.write!(config, "[commit]\n\tgpgsign = true\n[diff]\n\tnoprefix = true\n")
    System.put_env("GIT_CONFIG_GLOBAL", config)
    assert git(dir, ["config", "--get", "commit.gpgsign"]) == "true"
    assert git(dir, ["config", "--get", "diff.noprefix"]) == "true"

    Meerkat.TestHelpers.isolate_git_config()
    stage(dir, "file.txt", "before\n")
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "file.txt", "after\n")
    assert {:ok, [file]} = Git.staged_file_diffs(dir)
    assert file.file_name == "file.txt"
    assert file.read_errors == []
    assert Enum.join(file.hunks) =~ "+after"
  end

  test "Git interception handles executable paths and arguments containing apostrophes", %{
    dir: dir
  } do
    real_git = System.find_executable("git")
    old_path = System.fetch_env!("PATH")
    bin = Path.join(dir, "quoted'bin")
    File.mkdir_p!(bin)
    File.ln_s!(real_git, Path.join(bin, "git"))
    System.put_env("PATH", bin <> ":" <> old_path)
    on_exit(fn -> System.put_env("PATH", old_path) end)

    intercept_git(dir, "quoted'argument", "printf 'intercepted'; exit 0")
    assert git(dir, ["quoted'argument"]) == "intercepted"
    assert git(dir, ["--version"]) =~ "git version"
  end

  test "current_branch distinguishes a named branch from detached HEAD", %{dir: dir} do
    assert Git.current_branch(dir) == "main"
    git(dir, ["commit", "--allow-empty", "-qm", "base"])
    git(dir, ["checkout", "--detach", "-q"])
    assert Git.current_branch(dir) == nil
  end

  test "an empty successful branch lookup is still unnamed", %{dir: dir} do
    intercept_git(dir, "symbolic-ref", "printf '\\n'; exit 0")
    assert Git.current_branch(dir) == nil
  end

  test "missing staged blobs are not errors or approvals", %{dir: dir} do
    assert Git.fetch_staged_blob_oid(dir, "absent.txt") == :not_staged
    assert Git.staged_blob_oid(dir, "absent.txt") == ""
    stage(dir, "present.txt", "content\n")
    oid = git(dir, ["rev-parse", ":present.txt"])
    assert Git.fetch_staged_blob_oid(dir, "present.txt") == {:ok, oid}
    assert Git.staged_blob_oid(dir, "present.txt") == oid
  end

  test "generated convenience lookup respects explicit true, set and false attributes", %{
    dir: dir
  } do
    stage(
      dir,
      ".gitattributes",
      "yes.txt linguist-generated=true\nset.txt linguist-generated\nno.txt -linguist-generated\n"
    )

    assert Git.linguist_generated?(dir, "yes.txt")
    assert Git.linguist_generated?(dir, "set.txt")
    refute Git.linguist_generated?(dir, "no.txt")
    refute Git.linguist_generated?(dir, "unspecified.txt")
  end

  test "git directories distinguish linked-worktree state from shared state", %{dir: dir} do
    git(dir, ["commit", "--allow-empty", "-qm", "base"])
    linked = Path.join(dir, "linked")
    git(dir, ["worktree", "add", "-q", "-b", "linked", linked])
    expected = git(linked, ["rev-parse", "--absolute-git-dir"])
    assert Git.git_dir(linked) == {:ok, expected}
    assert {:ok, common} = Git.git_common_dir(linked)
    assert common == git(dir, ["rev-parse", "--absolute-git-dir"])
    refute common == expected

    old = Application.get_env(:meerkat, :meerkat_dir)
    Application.delete_env(:meerkat, :meerkat_dir)

    on_exit(fn ->
      if old,
        do: Application.put_env(:meerkat, :meerkat_dir, old),
        else: Application.delete_env(:meerkat, :meerkat_dir)
    end)

    assert Git.meerkat_dir(linked) == Path.join(expected, "meerkat-precommit")
  end

  test "staged text renames read the old path and retain both bodies", %{dir: dir} do
    before = "first\nsecond\nthird\nfourth\nfifth\n"
    stage(dir, "old.txt", before)
    git(dir, ["commit", "-qm", "base"])
    git(dir, ["mv", "old.txt", "new.txt"])
    after_text = before <> "sixth\n"
    stage(dir, "new.txt", after_text)

    assert {:ok, [file]} = Git.staged_file_diffs(dir)
    assert file.status == :renamed
    assert file.old_file_name == "old.txt"
    assert file.file_name == "new.txt"
    assert file.old_content == before
    assert file.new_content == after_text
    assert Enum.join(file.hunks) =~ "+sixth"
    assert file.read_errors == []
  end

  test "range materialisation preserves additions, deletions, modifications and rename context",
       %{dir: dir} do
    before = "first\nsecond\nthird\nfourth\nfifth\n"
    stage(dir, "old.txt", before)
    stage(dir, "gone.txt", "remove this\n")
    stage(dir, "changed.txt", "before\n")
    git(dir, ["commit", "-qm", "base"])
    base = git(dir, ["rev-parse", "HEAD"])
    git(dir, ["mv", "old.txt", "new.txt"])
    stage(dir, "new.txt", before <> "sixth\n")
    git(dir, ["rm", "gone.txt"])
    stage(dir, "changed.txt", "after\n")
    stage(dir, "added.txt", "brand new\n")
    git(dir, ["commit", "-qm", "changes"])

    assert {:ok, files} = Git.range_file_diffs(dir, base, "HEAD", :two_dot)
    by_name = Map.new(files, &{&1.file_name, &1})
    assert map_size(by_name) == 4
    assert by_name["added.txt"].status == :added
    assert by_name["added.txt"].old_content == ""
    assert by_name["added.txt"].new_content == "brand new\n"
    assert by_name["gone.txt"].status == :deleted
    assert by_name["gone.txt"].old_content == "remove this\n"
    assert by_name["gone.txt"].new_content == ""
    assert by_name["changed.txt"].status == :modified
    assert by_name["changed.txt"].old_content == "before\n"
    assert by_name["changed.txt"].new_content == "after\n"
    renamed = by_name["new.txt"]
    assert renamed.status == :renamed
    assert renamed.old_content == before
    assert renamed.new_content == before <> "sixth\n"
    assert Enum.join(renamed.hunks) =~ " third"
    refute Enum.join(renamed.hunks) =~ "+first"
    assert Enum.all?(files, &(&1.read_errors == [] and &1.effective_oid == nil))
  end

  test "three-dot bodies start at the fork rather than the latest base branch", %{dir: dir} do
    stage(dir, "file.txt", "common\n")
    git(dir, ["commit", "-qm", "fork"])
    git(dir, ["checkout", "-qb", "topic"])
    stage(dir, "file.txt", "topic\n")
    git(dir, ["commit", "-qm", "topic"])
    git(dir, ["checkout", "-q", "main"])
    stage(dir, "file.txt", "base moved\n")
    git(dir, ["commit", "-qm", "base moved"])

    assert {:ok, [file]} = Git.range_file_diffs(dir, "main", "topic", :three_dot)
    assert file.old_content == "common\n"
    assert file.new_content == "topic\n"
    assert Enum.join(file.hunks) =~ "-common"
    assert file.read_errors == []
  end

  test "fetch_pr uses the remote PR head and base refs and reports missing refs", %{dir: dir} do
    stage(dir, "file.txt", "base\n")
    git(dir, ["commit", "-qm", "base"])
    base = git(dir, ["rev-parse", "HEAD"])
    git(dir, ["checkout", "-qb", "topic"])
    stage(dir, "file.txt", "head\n")
    git(dir, ["commit", "-qm", "head"])
    head = git(dir, ["rev-parse", "HEAD"])
    git(dir, ["update-ref", "refs/pull/42/head", head])
    git(dir, ["remote", "add", "origin", dir])

    assert {:ok, {head_ref, base_ref}} = Git.fetch_pr(dir, 42, "main")
    assert head_ref == "refs/meerkat-pr/42/head"
    assert base_ref == "refs/meerkat-pr/42/base"
    assert git(dir, ["rev-parse", head_ref]) == head
    assert git(dir, ["rev-parse", base_ref]) == base
    assert {:error, reason} = Git.fetch_pr(dir, 43, "main")
    assert reason =~ "refs/pull/43/head"
  end

  test "Git command failures remain explicit instead of empty results", %{dir: dir} do
    intercept_git(dir, "--name-status", "exit 1")
    assert {:error, reason} = Git.staged_files(dir)
    assert reason =~ "exited 1"
  end

  test "batched OID lookup failures expose diagnostic errors", %{dir: dir} do
    intercept_git(dir, "-s", "echo index-unavailable >&2; exit 1")

    capture_io(:stderr, fn ->
      assert {:error, reason} = Git.staged_blob_oids_many(dir, ["file.txt"])
      assert reason =~ "index-unavailable"
      assert reason =~ "couldn't compute batched staged-blob OIDs"
    end)
  end

  test "HEAD lookup failure does not invent a deletion approval OID", %{dir: dir} do
    capture_io(:stderr, fn ->
      assert {:error, reason} = Git.head_blob_oids_many(dir, ["file.txt"])
      assert reason =~ "couldn't compute batched HEAD-blob OIDs"

      assert {:ok, %{}} =
               Git.effective_oids_many(dir, [%{file_name: "file.txt", status: :deleted}])
    end)
  end

  test "failed generated lookup is never treated as generated", %{dir: dir} do
    intercept_git(dir, "check-attr", "echo attrs-unavailable >&2; exit 1")

    capture_io(:stderr, fn ->
      assert %{"file.txt" => {:error, reason}} = Git.linguist_generated_many(dir, ["file.txt"])
      assert reason =~ "attrs-unavailable"
      refute Git.linguist_generated?(dir, "file.txt")
    end)
  end

  test "a failed batched patch remains visible as a read error", %{dir: dir} do
    stage(dir, "file.txt", "before\n")
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "file.txt", "after\n")
    intercept_git(dir, "-U3", "echo patch-unavailable >&2; exit 1")

    capture_io(:stderr, fn ->
      assert {:ok, [file]} = Git.staged_file_diffs(dir)
      assert file.old_content == "before\n"
      assert file.new_content == "after\n"
      assert file.hunks == []
      assert Enum.join(file.read_errors) =~ "patch-unavailable"
    end)
  end

  test "partial batched patches retain valid hunks and report the malformed block", %{dir: dir} do
    stage(dir, "file.txt", "before\n")
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "file.txt", "after\n")
    intercept_git(dir, "-U3", "printf 'diff --git malformed\\n'")

    capture_io(:stderr, fn ->
      assert {:ok, [file]} = Git.staged_file_diffs(dir)
      assert Enum.join(file.hunks) =~ "+after"
      assert Enum.join(file.read_errors) =~ "couldn't parse staged-diff block"
    end)
  end

  test "range patch failures expose errors while retaining readable bodies", %{dir: dir} do
    stage(dir, "file.txt", "before\n")
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "file.txt", "after\n")
    git(dir, ["commit", "-qm", "head"])
    intercept_git(dir, "-U3", "echo patch-unavailable >&2; exit 1")

    capture_io(:stderr, fn ->
      assert {:ok, [file]} = Git.range_file_diffs(dir, "HEAD~", "HEAD", :two_dot)
      assert file.old_content == "before\n"
      assert file.new_content == "after\n"
      assert file.hunks == []
      assert Enum.join(file.read_errors) =~ "patch-unavailable"
    end)
  end

  test "a failed merge-base lookup uses the supplied base for selected file bodies", %{dir: dir} do
    stage(dir, "file.txt", "common\n")
    git(dir, ["commit", "-qm", "fork"])
    git(dir, ["checkout", "-qb", "topic"])
    stage(dir, "file.txt", "topic\n")
    git(dir, ["commit", "-qm", "topic"])
    git(dir, ["checkout", "-q", "main"])
    stage(dir, "file.txt", "base moved\n")
    stage(dir, "base-only.txt", "base only\n")
    git(dir, ["commit", "-qm", "base moved"])
    intercept_git(dir, "merge-base", "exit 1")

    warning =
      capture_io(:stderr, fn ->
        assert {:ok, files} = Git.range_file_diffs(dir, "main", "topic", :three_dot)
        # This fallback only affects bodies: selection still uses three-dot.
        # Do not assert that it is a complete two-dot review (base-only changes
        # are currently omitted). That pre-existing range issue is separate.
        file = Enum.find(files, &(&1.file_name == "file.txt"))
        assert file.old_content == "base moved\n"
        assert file.new_content == "topic\n"
        assert Enum.join(file.hunks) =~ "-base moved"
        refute Enum.join(file.hunks) =~ "-common"
        assert file.read_errors == []
      end)

    assert warning =~ "couldn't resolve merge-base"
    assert warning =~ "Falling back to two-dot diff against main"
  end

  defp git(dir, args), do: dir |> Meerkat.TestHelpers.git(args) |> String.trim()
end
