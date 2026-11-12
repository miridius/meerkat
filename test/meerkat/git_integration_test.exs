defmodule Meerkat.GitIntegrationTest do
  use Meerkat.Case, async: false

  import ExUnit.CaptureIO
  alias Meerkat.Git

  import Meerkat.TestHelpers,
    only: [stage: 3, intercept_git: 3, import_commits: 2, stub_git: 1, stub_git: 2]

  # Built once; tests only read the repos, and a failure comes from
  # `stub_git`. `rebases` is on `main`, with linked worktrees stopped in
  # each kind of rebase; `staged` holds staged changes beside a merge
  # conflict; `range` holds the branches range reviews compare.
  setup_all do
    template =
      Meerkat.TestHelpers.fixture_template("meerkat-git-integration-template", fn dir ->
        build_rebases(Path.join(dir, "rebases"))
        build_staged(Path.join(dir, "staged"))
        build_range(Path.join(dir, "range"))
      end)

    {:ok,
     rebases: Path.join(template, "rebases"),
     staged: Path.join(template, "staged"),
     range: Path.join(template, "range")}
  end

  defp init(dir) do
    File.mkdir_p!(dir)
    git(dir, ["init", "-q", "--initial-branch=main"])
    git(dir, ["config", "user.email", "t@t.t"])
    git(dir, ["config", "user.name", "t"])
    git(dir, ["config", "core.hooksPath", "/dev/null"])
  end

  # `main` and `feature/x` each commit over one `base` commit. Parentless
  # commits of one tree are one commit, so `feature/x` starts at `main`'s.
  defp branch_off(dir, base, feature, main) do
    import_commits(dir, [
      {"refs/heads/main", base},
      {"refs/heads/feature/x", base},
      {"refs/heads/feature/x", feature},
      {"refs/heads/main", main}
    ])
  end

  defp build_rebases(dir) do
    init(dir)
    base = %{"file.txt" => "base\n"}
    branch_off(dir, base, %{"file.txt" => "feature\n"}, %{"file.txt" => "main\n"})
    git(dir, ["reset", "-q", "--hard"])

    # A hook-exported GIT_DIR would point this at meerkat's own repo.
    unset = Enum.map(~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE), &{&1, nil})
    apply = Path.join(dir, "linked-apply")
    git(dir, ["worktree", "add", "-q", apply, "feature/x"])
    opts = [cd: apply, stderr_to_stdout: true, env: unset]
    {_, code} = System.cmd("git", ["rebase", "-q", "--apply", "main"], opts)
    true = code != 0

    interactive = Path.join(dir, "linked")
    git(dir, ["worktree", "add", "-q", "-b", "feature/linked", interactive])
    stop_at_edit(interactive)
  end

  defp build_staged(dir) do
    init(dir)
    before = "first\nsecond\nthird\nfourth\nfifth\n"
    base = %{"conflict.txt" => "base\n", "file.txt" => "before\n", "old.txt" => before}

    branch_off(dir, base, %{base | "conflict.txt" => "feature\n"}, %{
      base
      | "conflict.txt" => "main\n"
    })

    git(dir, ["reset", "-q", "--hard"])

    unset = Enum.map(~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE), &{&1, nil})
    opts = [cd: dir, stderr_to_stdout: true, env: unset]
    {_, code} = System.cmd("git", ["merge", "-q", "feature/x"], opts)
    true = code != 0

    stage(dir, "file.txt", "after\n")
    git(dir, ["mv", "old.txt", "new.txt"])
    stage(dir, "new.txt", before <> "sixth\n")
    # Staged files on both sides of the conflict in path order.
    stage(dir, "a.txt", "a\n")
    stage(dir, "z.txt", "z\n")

    File.write!(
      Path.join(dir, ".gitattributes"),
      "yes.txt linguist-generated=true\nset.txt linguist-generated\nno.txt -linguist-generated\n"
    )
  end

  # `changes`, compared with `base` for two-dot reviews; `topic` off
  # `fork`, and `moved` past it, for three-dot ones. `refs/pull/42/head`
  # is the tip of a PR into `main`, fetched from `origin`, the repo itself.
  defp build_range(dir) do
    init(dir)
    before = "first\nsecond\nthird\nfourth\nfifth\n"

    base = %{
      "old.txt" => before,
      "gone.txt" => "remove this\n",
      "changed.txt" => "before\n"
    }

    fork = %{"file.txt" => "common\n"}

    # As in `branch_off/4`, `topic` and `moved` start at `fork`'s commit.
    commits =
      import_commits(dir, [
        {"refs/heads/base", base},
        {"refs/heads/changes",
         %{
           "new.txt" => before <> "sixth\n",
           "changed.txt" => "after\n",
           "added.txt" => "brand new\n"
         }},
        {"refs/heads/fork", fork},
        {"refs/heads/topic", fork},
        {"refs/heads/topic", %{"file.txt" => "topic\n"}},
        {"refs/heads/moved", fork},
        {"refs/heads/moved", %{"file.txt" => "base moved\n", "base-only.txt" => "base only\n"}},
        {"refs/heads/main", base},
        {"refs/heads/pr", %{"changed.txt" => "head\n"}}
      ])

    git(dir, ["update-ref", "refs/pull/42/head", List.last(commits)])
    git(dir, ["remote", "add", "origin", dir])
  end

  test "Git helpers isolate global signing and diff-prefix settings", %{staged: staged} do
    config = Meerkat.TestHelpers.tmp_path("meerkat-git-integration-config")
    on_exit(fn -> File.rm(config) end)
    File.write!(config, "[commit]\n\tgpgsign = true\n[diff]\n\tnoprefix = true\n")
    Meerkat.TestHelpers.put_env("GIT_CONFIG_GLOBAL", config)
    assert git(staged, ["config", "--get", "commit.gpgsign"]) == "true"
    assert git(staged, ["config", "--get", "diff.noprefix"]) == "true"

    Meerkat.TestHelpers.put_git_config_env()
    assert {:ok, files} = Git.staged_file_diffs(staged)
    file = Enum.find(files, &(&1.file_name == "file.txt"))
    assert file.read_errors == []
    assert Enum.join(file.hunks) =~ "+after"
  end

  test "Git interception handles executable paths and arguments containing apostrophes" do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-git-integration-intercept")
    on_exit(fn -> File.rm_rf!(dir) end)
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

  test "current_branch distinguishes a named branch from detached HEAD", %{rebases: rebases} do
    assert Git.current_branch(rebases) == "main"
    stub_git("symbolic-ref", {"fatal: ref HEAD is not a symbolic ref", 1})
    assert Git.current_branch(rebases) == nil
  end

  test "mid interactive rebase, a linked worktree's branch is the one it is rebasing", %{
    rebases: rebases
  } do
    linked = Path.join(rebases, "linked")
    assert Git.head_branch(linked) == {:rebasing, "feature/linked"}
    assert Git.current_branch(linked) == "feature/linked"
    assert Git.head_branch(rebases) == {:checked_out, "main"}
  end

  test "an --apply rebase stopped on a conflict names the branch being rebased", %{
    rebases: rebases
  } do
    linked = Path.join(rebases, "linked-apply")
    assert File.exists?(git(linked, ["rev-parse", "--git-path", "rebase-apply/head-name"]))
    assert Git.head_branch(linked) == {:rebasing, "feature/x"}
  end

  # The `head-name` git writes for a rebase started from a detached HEAD.
  test "a rebase started from a detached HEAD belongs to no branch", %{rebases: rebases} do
    head_name = Meerkat.TestHelpers.tmp_path("meerkat-git-integration-head-name")
    on_exit(fn -> File.rm(head_name) end)
    File.write!(head_name, "detached HEAD\n")

    stub_git(fn
      [_git, "symbolic-ref" | _] -> {"", 1}
      [_git, "rev-parse" | _] -> {"#{head_name}.absent\n#{head_name}\n", 0}
    end)

    assert Git.head_branch(rebases) == :detached
    assert Git.current_branch(rebases) == nil
  end

  test "an empty successful branch lookup is still unnamed", %{rebases: rebases} do
    stub_git("symbolic-ref", {"\n", 0})
    assert Git.current_branch(rebases) == nil
  end

  test "missing staged blobs are not errors or approvals", %{staged: staged} do
    assert Git.fetch_staged_blob_oid(staged, "absent.txt") == :not_staged
    assert Git.staged_blob_oid(staged, "absent.txt") == ""
    oid = git(staged, ["rev-parse", ":a.txt"])
    assert Git.fetch_staged_blob_oid(staged, "a.txt") == {:ok, oid}
    assert Git.staged_blob_oid(staged, "a.txt") == oid
  end

  test "generated convenience lookup respects explicit true, set and false attributes", %{
    staged: staged
  } do
    assert Git.linguist_generated?(staged, "yes.txt")
    assert Git.linguist_generated?(staged, "set.txt")
    refute Git.linguist_generated?(staged, "no.txt")
    refute Git.linguist_generated?(staged, "unspecified.txt")
  end

  test "git directories distinguish linked-worktree state from shared state", %{
    rebases: rebases
  } do
    linked = Path.join(rebases, "linked")
    expected = git(linked, ["rev-parse", "--absolute-git-dir"])
    assert Git.git_dir(linked) == {:ok, expected}
    assert {:ok, common} = Git.git_common_dir(linked)
    assert common == git(rebases, ["rev-parse", "--absolute-git-dir"])
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

  test "staged text renames read the old path and retain both bodies", %{staged: staged} do
    before = "first\nsecond\nthird\nfourth\nfifth\n"
    assert {:ok, files} = Git.staged_file_diffs(staged)
    file = Enum.find(files, &(&1.file_name == "new.txt"))
    assert file.status == :renamed
    assert file.old_file_name == "old.txt"
    assert file.old_content == before
    assert file.new_content == before <> "sixth\n"
    assert Enum.join(file.hunks) =~ "+sixth"
    assert file.read_errors == []
  end

  test "an unresolved conflict is left out and the other staged files remain", %{
    staged: staged
  } do
    assert git(staged, ["diff", "--cached", "--name-status"]) =~ ~r/^U\tconflict\.txt$/m

    assert {:ok, entries} = Git.staged_files(staged)
    assert Enum.map(entries, & &1.file_name) == ["a.txt", "file.txt", "new.txt", "z.txt"]
    assert {:ok, [a, _file, _new, z]} = Git.staged_file_diffs(staged)
    assert {a.file_name, Enum.join(a.hunks)} == {"a.txt", "@@ -0,0 +1,1 @@\n+a\n"}
    assert {z.file_name, Enum.join(z.hunks)} == {"z.txt", "@@ -0,0 +1,1 @@\n+z\n"}
    assert a.read_errors == [] and z.read_errors == []
  end

  test "range materialisation preserves additions, deletions, modifications and rename context",
       %{range: range} do
    before = "first\nsecond\nthird\nfourth\nfifth\n"
    assert {:ok, files} = Git.range_file_diffs(range, "base", "changes", :two_dot)
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

  test "three-dot bodies start at the fork rather than the latest base branch", %{range: range} do
    assert {:ok, [file]} = Git.range_file_diffs(range, "moved", "topic", :three_dot)
    assert file.old_content == "common\n"
    assert file.new_content == "topic\n"
    assert Enum.join(file.hunks) =~ "-common"
    assert file.read_errors == []
  end

  # Writes only its own `refs/meerkat-pr/42/*`, which no other test reads.
  test "fetch_pr uses the remote PR head and base refs and reports missing refs", %{
    range: range
  } do
    assert {:ok, {head_ref, base_ref}} = Git.fetch_pr(range, 42, "main")
    assert head_ref == "refs/meerkat-pr/42/head"
    assert base_ref == "refs/meerkat-pr/42/base"
    assert git(range, ["rev-parse", head_ref]) == git(range, ["rev-parse", "pr"])
    assert git(range, ["rev-parse", base_ref]) == git(range, ["rev-parse", "main"])
    assert {:error, reason} = Git.fetch_pr(range, 43, "main")
    assert reason =~ "refs/pull/43/head"
  end

  test "Git command failures remain explicit instead of empty results", %{staged: staged} do
    stub_git("--name-status", {"", 1})
    assert {:error, reason} = Git.staged_files(staged)
    assert reason =~ "exited 1"
  end

  test "batched OID lookup failures expose diagnostic errors", %{staged: staged} do
    stub_git("-s", {"index-unavailable\n", 1})

    capture_io(:stderr, fn ->
      assert {:error, reason} = Git.staged_blob_oids_many(staged, ["file.txt"])
      assert reason =~ "index-unavailable"
      assert reason =~ "couldn't compute batched staged-blob OIDs"
    end)
  end

  test "HEAD lookup failure does not invent a deletion approval OID", %{staged: staged} do
    stub_git("ls-tree", {"fatal: Not a valid object name HEAD\n", 128})

    capture_io(:stderr, fn ->
      assert {:error, reason} = Git.head_blob_oids_many(staged, ["file.txt"])
      assert reason =~ "couldn't compute batched HEAD-blob OIDs"

      assert {:ok, %{}} =
               Git.effective_oids_many(staged, [%{file_name: "file.txt", status: :deleted}])
    end)
  end

  test "failed generated lookup is never treated as generated", %{staged: staged} do
    stub_git("check-attr", {"attrs-unavailable\n", 1})

    capture_io(:stderr, fn ->
      assert %{"yes.txt" => {:error, reason}} = Git.linguist_generated_many(staged, ["yes.txt"])
      assert reason =~ "attrs-unavailable"
      refute Git.linguist_generated?(staged, "yes.txt")
    end)
  end

  test "a failed batched patch remains visible as a read error", %{staged: staged} do
    stub_git("-U3", {"patch-unavailable\n", 1})

    capture_io(:stderr, fn ->
      file = staged_file(staged, "file.txt")
      assert file.old_content == "before\n"
      assert file.new_content == "after\n"
      assert file.hunks == []
      assert Enum.join(file.read_errors) =~ "patch-unavailable"
    end)
  end

  test "partial batched patches retain valid hunks and report the malformed block", %{
    staged: staged
  } do
    stub_git("-U3", fn [_git | args] ->
      {out, 0} = System.cmd("git", args, cd: staged)
      {"diff --git malformed\n" <> out, 0}
    end)

    capture_io(:stderr, fn ->
      file = staged_file(staged, "file.txt")
      assert Enum.join(file.hunks) =~ "+after"
      assert Enum.join(file.read_errors) =~ "couldn't parse staged-diff block"
    end)
  end

  test "range patch failures expose errors while retaining readable bodies", %{range: range} do
    stub_git("-U3", {"patch-unavailable\n", 1})

    capture_io(:stderr, fn ->
      assert {:ok, files} = Git.range_file_diffs(range, "base", "changes", :two_dot)
      file = Enum.find(files, &(&1.file_name == "changed.txt"))
      assert file.old_content == "before\n"
      assert file.new_content == "after\n"
      assert file.hunks == []
      assert Enum.join(file.read_errors) =~ "patch-unavailable"
    end)
  end

  test "a failed merge-base lookup uses the supplied base for selected file bodies", %{
    range: range
  } do
    stub_git("merge-base", {"", 1})

    warning =
      capture_io(:stderr, fn ->
        assert {:ok, files} = Git.range_file_diffs(range, "moved", "topic", :three_dot)
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
    assert warning =~ "Falling back to two-dot diff against moved"
  end

  defp staged_file(staged, name) do
    assert {:ok, files} = Git.staged_file_diffs(staged)
    Enum.find(files, &(&1.file_name == name))
  end

  defp git(dir, args), do: dir |> Meerkat.TestHelpers.git(args) |> String.trim()

  # Two more commits, then `git rebase -i` stopped at an `edit` of the
  # first: HEAD detached, rebase in progress.
  defp stop_at_edit(dir) do
    git(dir, ["commit", "--allow-empty", "-qm", "one"])
    git(dir, ["commit", "--allow-empty", "-qm", "two"])
    editor = "sequence.editor=sed -i.bak -e '1s/^pick/edit/'"
    git(dir, ["-c", editor, "rebase", "-q", "-i", "HEAD~2"])
    assert git(dir, ["status", "--short", "--branch"]) =~ "## HEAD (no branch)"
  end
end
