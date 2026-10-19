defmodule Meerkat.GitBinaryTest do
  use Meerkat.Case, async: false

  alias Meerkat.Git

  import Meerkat.TestHelpers, only: [stage: 3, intercept_git: 3, git: 2]

  setup do
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-binary")
    git(dir, ["init", "-q"])
    git(dir, ["config", "user.email", "t@t.t"])
    git(dir, ["config", "user.name", "t"])
    git(dir, ["config", "core.hooksPath", "/dev/null"])
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "a text file git calls binary only through -diff shows its lines", %{dir: dir} do
    stage(dir, "BUILD.bazel", "a\nb\nc\n")
    stage(dir, "query.clj", "(old-query)\n")
    stage(dir, "spaces.txt", "old text\n")
    git(dir, ["commit", "-qm", "base"])
    File.write!(Path.join(dir, ".git/info/attributes"), "/BUILD.bazel -diff\n")
    stage(dir, "BUILD.bazel", "a\nB\nc\nd\n")
    stage(dir, "query.clj", "(new-query)\n")
    stage(dir, "spaces.txt", "old   text\n")

    assert git(dir, ["diff", "--cached", "--numstat"]) =~ "-\t-\tBUILD.bazel"

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, [bazel, text]} = Git.staged_file_diffs(dir)
        assert bazel.file_name == "BUILD.bazel"
        refute bazel.is_binary
        assert Enum.join(bazel.hunks) =~ "-b\n+B\n c\n+d"
        assert {bazel.additions, bazel.deletions} == {2, 1}
        assert bazel.new_content == "a\nB\nc\nd\n"
        assert bazel.read_errors == []
        refute text.is_binary
        assert Enum.join(text.hunks) =~ "+(new-query)"
      end)

    refute stderr =~ "couldn't parse"
  end

  test "a -diff file stays binary when its content or the binary macro says so", %{dir: dir} do
    stage(dir, ".gitattributes", "*.gen -diff\nmacro.gen binary\n")
    stage(dir, "nul.gen", "old\n")
    stage(dir, "macro.gen", "old\n")
    stage(dir, "late-nul.gen", "old\n")
    stage(dir, "last-nul.gen", "old\n")
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "nul.gen", "new" <> <<0>> <> "\n")
    stage(dir, "macro.gen", "new\n")
    # git's test reads only the first 8000 bytes.
    stage(dir, "late-nul.gen", String.duplicate("x", 8000) <> <<0>>)
    stage(dir, "last-nul.gen", String.duplicate("x", 7999) <> <<0>>)

    assert {:ok, files} = Git.staged_file_diffs(dir)
    by_name = Map.new(files, &{&1.file_name, &1})
    assert_binary(by_name["nul.gen"], :modified)
    assert_binary(by_name["macro.gen"], :modified)
    assert_binary(by_name["last-nul.gen"], :modified)
    refute by_name["late-nul.gen"].is_binary
  end

  test "a -diff text file renamed from an unmarked path shows its lines, and one renamed " <>
         "under the binary macro stays binary",
       %{dir: dir} do
    stage(dir, ".gitattributes", "*.gen -diff\n*.bin binary\n")
    stage(dir, "plain.txt", Enum.map_join(1..20, &"plain #{&1}\n"))
    stage(dir, "marked.gen", Enum.map_join(1..20, &"marked #{&1}\n"))
    git(dir, ["commit", "-qm", "base"])
    git(dir, ["mv", "plain.txt", "plain.gen"])
    git(dir, ["mv", "marked.gen", "marked.bin"])

    assert {:ok, files} = Git.staged_file_diffs(dir)
    by_name = Map.new(files, &{&1.file_name, &1})
    refute by_name["plain.gen"].is_binary
    assert by_name["plain.gen"].new_content =~ "plain 20"
    assert_binary(by_name["marked.bin"], :renamed)
  end

  test "a deleted -diff text file shows its removed lines", %{dir: dir} do
    stage(dir, ".gitattributes", "*.gen -diff\n")
    stage(dir, "gone.gen", "one\ntwo\n")
    git(dir, ["commit", "-qm", "base"])
    git(dir, ["rm", "-q", "gone.gen"])

    assert {:ok, [file]} = Git.staged_file_diffs(dir)
    assert file.status == :deleted
    refute file.is_binary
    assert {file.additions, file.deletions} == {0, 2}
  end

  test "a -diff file whose old side holds a NUL stays binary", %{dir: dir} do
    stage(dir, ".gitattributes", "*.gen -diff\n")
    stage(dir, "a.gen", "old" <> <<0>>)
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "a.gen", "new\n")

    assert {:ok, [file]} = Git.staged_file_diffs(dir)
    assert_binary(file, :modified)
  end

  test "a -diff text side over the 4 MiB cap stays binary", %{dir: dir} do
    stage(dir, ".gitattributes", "*.gen -diff\n")
    stage(dir, "big.gen", String.duplicate("x", 4 * 1024 * 1024) <> "\n")
    stage(dir, "cap.gen", String.duplicate("x", 4 * 1024 * 1024 - 1) <> "\n")

    assert {:ok, files} = Git.staged_file_diffs(dir)
    by_name = Map.new(files, &{&1.file_name, &1})
    assert_binary(by_name["big.gen"], :added)
    refute by_name["cap.gen"].is_binary
  end

  test "a -diff file whose content probe fails stays binary", %{dir: dir} do
    stage(dir, ".gitattributes", "*.gen -diff\n")
    stage(dir, "a.gen", "text\n")
    stage(dir, "b.gen", "text\n")

    intercept_git(dir, "cat-file", """
    case "$*" in *"-s :0:a.gen"*|*"blob :0:b.gen"*) exit 1;; esac
    """)

    assert {:ok, [_attributes, a, b]} = Git.staged_file_diffs(dir)
    assert_binary(a, :added)
    assert_binary(b, :added)
  end

  test "a path check-attr leaves out gets an error, not an answer", %{dir: dir} do
    intercept_git(dir, "check-attr", "exit 0")

    assert Git.linguist_generated_many(dir, ["a.txt"]) == %{
             "a.txt" => {:error, "`git check-attr` returned no row for a.txt"}
           }
  end

  test "a review with no binary file looks up no diff attribute", %{dir: dir} do
    stage(dir, "a.txt", "text\n")
    log = Path.join(dir, "check-attr.log")
    intercept_git(dir, "check-attr", "echo \"$*\" >> '#{log}'")

    assert {:ok, [_file]} = Git.staged_file_diffs(dir)
    refute File.read!(log) =~ "diff"
  end

  test "a renamed -diff text file shows its lines and an attribute lookup failure keeps it binary",
       %{dir: dir} do
    stage(dir, ".gitattributes", "*.gen -diff\n")
    stage(dir, "old.gen", Enum.map_join(1..20, &"line #{&1}\n"))
    git(dir, ["commit", "-qm", "base"])
    git(dir, ["mv", "old.gen", "new.gen"])
    stage(dir, "new.gen", Enum.map_join(1..20, &"line #{&1}\n") <> "extra\n")

    assert {:ok, [file]} = Git.staged_file_diffs(dir)
    assert file.status == :renamed
    refute file.is_binary
    assert Enum.join(file.hunks) =~ "+extra"
    assert {file.additions, file.deletions} == {1, 0}

    intercept_git(dir, "binary", "exit 1")

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert {:ok, [file]} = Git.staged_file_diffs(dir)
      assert_binary(file, :renamed)
    end)
  end

  test "a range review shows a -diff text file's lines and keeps real binaries binary", %{
    dir: dir
  } do
    stage(dir, ".gitattributes", "*.gen -diff\n")
    stage(dir, "a.gen", "one\n")
    stage(dir, "nul.gen", "one\n")
    stage(dir, "moved.gen", Enum.map_join(1..20, &"line #{&1}\n"))
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "a.gen", "two\n")
    stage(dir, "nul.gen", <<0>>)
    git(dir, ["mv", "moved.gen", "renamed.gen"])
    stage(dir, "renamed.gen", Enum.map_join(1..20, &"line #{&1}\n") <> "extra\n")
    git(dir, ["commit", "-qm", "head"])

    assert {:ok, [a, nul, renamed]} = Git.range_file_diffs(dir, "HEAD~1", "HEAD", :two_dot)
    refute a.is_binary
    assert Enum.join(a.hunks) =~ "-one\n+two"
    assert {a.additions, a.deletions} == {1, 1}
    assert nul.is_binary
    assert nul.hunks == []
    refute renamed.is_binary
    assert renamed.status == :renamed
    assert Enum.join(renamed.hunks) =~ "+extra"
  end

  test "actual binary bytes are removed before JSON encoding, even in a binary-only review", %{
    dir: dir
  } do
    stage(dir, "BUILD.bazel", <<0, 255, 1>>)
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "BUILD.bazel", <<0, 254, 2>>)

    assert {:ok, [file]} = Git.staged_file_diffs(dir)
    assert_binary(file, :modified)
    assert file.effective_oid == git(dir, ["rev-parse", ":BUILD.bazel"])
    assert Jason.encode!(file) =~ "is_binary"
  end

  test "a binary deletion whose HEAD blob lookup fails carries an empty OID", %{dir: dir} do
    stage(dir, "gone.bin", <<0, 255>>)
    git(dir, ["commit", "-qm", "base"])
    git(dir, ["rm", "-q", "gone.bin"])
    intercept_git(dir, "ls-tree", "exit 1")

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert {:ok, [file]} = Git.staged_file_diffs(dir)
      assert file.is_binary
      assert file.effective_oid == ""
    end)
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

  test "mixed text and binary additions, deletions, renames and generated files", %{dir: dir} do
    stage(dir, ".gitattributes", "generated.bin linguist-generated=true\n")
    stage(dir, "gone.bin", "old deleted" <> <<0>>)
    stage(dir, "old.bin", "renamed content" <> <<0>>)
    stage(dir, "query.clj", "(old-query)\n")
    git(dir, ["commit", "-qm", "base"])
    git(dir, ["rm", "-q", "gone.bin"])
    git(dir, ["mv", "old.bin", "new.bin"])
    stage(dir, "query.clj", "(new-query)\n")
    stage(dir, "added.md", "# Binary" <> <<0>>)
    stage(dir, "generated.bin", "generated binary content" <> <<0>>)

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, files} = Git.staged_file_diffs(dir)
        by_name = Map.new(files, &{&1.file_name, &1})

        assert Enum.sort(Map.keys(by_name)) ==
                 ~w(added.md generated.bin gone.bin new.bin query.clj)

        assert_binary(by_name["gone.bin"], :deleted)
        assert_binary(by_name["new.bin"], :renamed)
        assert by_name["new.bin"].old_file_name == "old.bin"
        assert_binary(by_name["added.md"], :added)
        assert_binary(by_name["generated.bin"], :added)
        assert by_name["generated.bin"].is_generated
        refute by_name["new.bin"].is_generated
        refute by_name["query.clj"].is_binary
        assert Enum.join(by_name["query.clj"].hunks) =~ "+(new-query)"
      end)

    refute stderr =~ "couldn't parse staged-diff block"
  end

  test "numstat failure keeps every file listed with the reason", %{dir: dir} do
    stage(dir, "BUILD.bazel", <<0, 255>>)
    intercept_git(dir, "--numstat", "echo numstat-failed >&2; exit 1")

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert {:ok, [file]} = Git.staged_file_diffs(dir)
      assert file.file_name == "BUILD.bazel"
      assert Enum.join(file.read_errors) =~ "couldn't identify binary files"
      assert Enum.join(file.read_errors) =~ "exited 1"
    end)
  end

  test "numstat output truncated mid-entry degrades to a listed read error", %{dir: dir} do
    stage(dir, "a.txt", "one\n")
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "a.txt", "two\n")

    # A rename entry cut off before the trailing NUL makes the parser run
    # off the end of the entry list instead of seeing the empty tail.
    intercept_git(dir, "--numstat", """
    printf '1\\t2\\t\\0old.bin\\0new.bin'; exit 0
    """)

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, [file]} = Git.staged_file_diffs(dir)
        assert file.file_name == "a.txt"
        assert Enum.join(file.read_errors) =~ "couldn't parse binary file statistics"
      end)

    assert stderr =~ "couldn't parse binary file statistics"
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

  test "a range review marks binary files, renames included, without reading their blobs", %{
    dir: dir
  } do
    stage(dir, "logo.png", <<0, 255, 1>>)
    stage(dir, "moved.bin", <<0, 253, 3>>)
    stage(dir, "text.txt", "old\n")
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "logo.png", <<0, 254, 2>>)
    git(dir, ["mv", "moved.bin", "renamed.bin"])
    stage(dir, "new.bin", <<0, 252>>)
    stage(dir, "text.txt", "new\n")
    git(dir, ["commit", "-qm", "head"])
    intercept_git(dir, "show", "echo unexpected-blob-read >&2; exit 1")

    assert {:ok, [logo, new, renamed, text]} =
             Git.range_file_diffs(dir, "HEAD~1", "HEAD", :two_dot)

    assert_binary(logo, :modified)
    assert_binary(new, :added)
    assert_binary(renamed, :renamed)
    assert renamed.old_file_name == "moved.bin"
    # The text file's reads hit the intercept, so a binary read would too.
    refute text.is_binary
    assert text.read_errors != []
  end

  test "a range review keeps every file listed with the reason when numstat fails", %{dir: dir} do
    stage(dir, "text.txt", "old\n")
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "text.txt", "new\n")
    git(dir, ["commit", "-qm", "head"])
    intercept_git(dir, "--numstat", "exit 1")

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert {:ok, [file]} = Git.range_file_diffs(dir, "HEAD~1", "HEAD", :two_dot)
      refute file.is_binary
      assert file.hunks != []
      assert Enum.join(file.read_errors) =~ "couldn't identify binary files"
    end)
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
