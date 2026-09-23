defmodule Meerkat.GitBinaryTest do
  use ExUnit.Case, async: false

  alias Meerkat.Git

  import Meerkat.TestHelpers, only: [stage: 3, intercept_git: 3, git: 2]

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-binary")
    git(dir, ["init", "-q"])
    git(dir, ["config", "user.email", "t@t.t"])
    git(dir, ["config", "user.name", "t"])
    git(dir, ["config", "core.hooksPath", "/dev/null"])
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "attribute-classified BUILD.bazel remains visible beside text changes", %{dir: dir} do
    stage(dir, ".gitattributes", "BUILD.bazel -diff\n")
    stage(dir, "BUILD.bazel", "old target\n")
    stage(dir, "query.clj", "(old-query)\n")
    stage(dir, "spaces.txt", "old text\n")
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "BUILD.bazel", "new target\n")
    stage(dir, "query.clj", "(new-query)\n")
    stage(dir, "spaces.txt", "old   text\n")

    assert git(dir, ["diff", "--cached", "--stat"]) =~ "Bin"

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, files} = Git.staged_file_diffs(dir)
        assert Enum.map(files, & &1.file_name) == ["BUILD.bazel", "query.clj"]
        [binary, text] = files
        assert_binary(binary, :modified)
        refute binary.is_generated
        refute text.is_binary
        assert Enum.join(text.hunks) =~ "+(new-query)"
        assert text.read_errors == []
      end)

    refute stderr =~ "couldn't parse"
  end

  test "actual binary bytes are removed before JSON encoding, even in a binary-only review", %{
    dir: dir
  } do
    stage(dir, "BUILD.bazel", <<0, 255, 1>>)
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "BUILD.bazel", <<0, 254, 2>>)

    assert {:ok, [file]} = Git.staged_file_diffs(dir)
    assert_binary(file, :modified)
    assert Jason.encode!(file) =~ "is_binary"
  end

  test "binary additions in an unborn repository are represented explicitly", %{dir: dir} do
    stage(dir, "new.bin", <<0, 255>>)
    assert {:ok, [file]} = Git.staged_file_diffs(dir)
    assert_binary(file, :added)
  end

  test "binary deletion and exact rename retain status and unambiguous paths", %{dir: dir} do
    old = "old b/name with spaces.bin"
    new = "new b/name with spaces.bin"
    stage(dir, old, <<0, 255, 1>>)
    stage(dir, "gone.bin", <<0, 254, 2>>)
    git(dir, ["commit", "-qm", "base"])
    git(dir, ["config", "diff.renames", "false"])
    File.mkdir_p!(Path.dirname(Path.join(dir, new)))
    git(dir, ["mv", old, new])
    git(dir, ["rm", "gone.bin"])

    assert {:ok, files} = Git.staged_file_diffs(dir)
    assert length(files) == 2
    deleted = Enum.find(files, &(&1.status == :deleted))
    renamed = Enum.find(files, &(&1.status == :renamed))
    assert_binary(deleted, :deleted)
    assert_binary(renamed, :renamed)
    assert renamed.file_name == new
    assert renamed.old_file_name == old
  end

  test "numstat failure keeps every file listed with the reason", %{dir: dir} do
    stage(dir, "BUILD.bazel", <<0, 255>>)
    intercept_git(dir, "--numstat", "echo numstat-failed >&2; exit 1")

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert {:ok, [file]} = Git.staged_file_diffs(dir)
      assert file.file_name == "BUILD.bazel"
      assert Enum.join(file.read_errors) =~ "couldn't identify staged binary files"
      assert Enum.join(file.read_errors) =~ "exited 1"
    end)
  end

  test "numstat output truncated mid-entry degrades to a listed read error", %{dir: dir} do
    stage(dir, "a.txt", "one\n")
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "a.txt", "two\n")

    # A rename entry cut off before the trailing NUL makes the parser run
    # off the end of the entry list instead of seeing the empty tail.
    intercept_git(dir, "--numstat", '''
    printf '1\\t2\\t\\0old.bin\\0new.bin'; exit 0
    ''')

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, [file]} = Git.staged_file_diffs(dir)
        assert file.file_name == "a.txt"
        assert Enum.join(file.read_errors) =~ "couldn't parse staged binary file statistics"
      end)

    assert stderr =~ "couldn't parse staged binary file statistics"
  end

  test "a stability re-check that fails reports the git error instead of crashing", %{dir: dir} do
    stage(dir, "a.txt", "one\n")
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "a.txt", "two\n")

    # Both index probes run `ls-files --stage`; fail only the second.
    counter = Path.join(dir, "stage-probe-count")

    intercept_git(dir, "--stage", """
    n=$(cat '#{counter}' 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > '#{counter}'
    [ "$n" -ge 2 ] && { echo stage-probe-failed >&2; exit 1; }
    """)

    assert {:error, reason} = Git.staged_file_diffs(dir)
    assert reason =~ "ls-files"
  end

  test "patch parse failure survives whitespace filtering as visible read errors", %{dir: dir} do
    stage(dir, "file.txt", "old\n")
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "file.txt", "new\n")
    intercept_git(dir, "-U3", "printf 'diff --git malformed\\n@@ -1 +1 @@\\n-x\\n+y\\n'; exit 0")

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert {:ok, [file]} = Git.staged_file_diffs(dir)
      assert file.file_name == "file.txt"
      assert file.hunks == []
      assert Enum.join(file.read_errors) =~ "couldn't parse staged-diff block"
    end)
  end

  test "valid hunks survive an unrelated malformed block" do
    diff =
      "diff --git malformed\n@@ -1 +1 @@\n-x\n+y\n" <>
        "diff --git a/good.txt b/good.txt\n--- a/good.txt\n+++ b/good.txt\n@@ -1 +1 @@\n-old\n+new\n"

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert {:partial, %{"good.txt" => {hunks, []}}, reason} =
               Git.parse_multi_file_diff_for_test(diff)

      assert Enum.join(hunks) =~ "+new"
      assert reason =~ "couldn't parse staged-diff block"
    end)
  end

  test "binary blobs are not read for the notice", %{dir: dir} do
    stage(dir, "asset.bin", <<0, 255>>)
    intercept_git(dir, "show", "echo unexpected-blob-read >&2; exit 1")
    assert {:ok, [file]} = Git.staged_file_diffs(dir)
    assert_binary(file, :added)
  end

  test "successful numstat warnings do not corrupt structured output", %{dir: dir} do
    stage(dir, "asset.bin", <<0, 255>>)
    intercept_git(dir, "--numstat", "echo rename-warning >&2")
    assert {:ok, [file]} = Git.staged_file_diffs(dir)
    assert_binary(file, :added)
  end

  test "index changes during loading require a reload", %{dir: dir} do
    stage(dir, "file.txt", "old\n")
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "file.txt", "new\n")

    intercept_git(
      dir,
      "--numstat",
      "printf 'changed again\\n' > file.txt; \"$real_git\" add file.txt"
    )

    assert {:error, reason} = Git.staged_file_diffs(dir)
    assert reason =~ "staged files changed while loading"
  end

  defp assert_binary(file, status) do
    assert file.is_binary
    assert file.status == status
    assert file.old_content == ""
    assert file.new_content == ""
    assert file.hunks == []
    assert file.read_errors == []
    assert file.effective_oid != ""
  end
end
