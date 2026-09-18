defmodule Meerkat.GitBinaryTest do
  use ExUnit.Case, async: false

  alias Meerkat.Git

  @git_env Enum.map(
             ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
                GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE),
             &{&1, nil}
           )

  setup do
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

  test "numstat failure aborts loading instead of losing a binary change", %{dir: dir} do
    stage(dir, "BUILD.bazel", <<0, 255>>)
    intercept_git(dir, "--numstat", "echo numstat-failed >&2; exit 1")
    assert {:error, reason} = Git.staged_file_diffs(dir)
    assert reason =~ "couldn't identify staged binary files"
    assert reason =~ "exited 1"
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
    real_git = System.find_executable("git")

    intercept_git(
      dir,
      "--numstat",
      "printf 'changed again\\n' > file.txt; '#{real_git}' add file.txt"
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

  defp stage(dir, name, content) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    git(dir, ["add", "--", name])
  end

  defp git(dir, args) do
    {out, code} = System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: @git_env)
    assert code == 0, out
    out
  end

  defp intercept_git(dir, arg, action) do
    real_git = System.find_executable("git")
    old_path = System.fetch_env!("PATH")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "git"), """
    #!/bin/sh
    for arg in "$@"; do
      if [ "$arg" = '#{arg}' ]; then
        #{action}
      fi
    done
    exec '#{real_git}' "$@"
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)
    System.put_env("PATH", bin <> ":" <> old_path)
    on_exit(fn -> System.put_env("PATH", old_path) end)
  end
end
