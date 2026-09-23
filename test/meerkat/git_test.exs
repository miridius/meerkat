defmodule Meerkat.GitTest do
  use ExUnit.Case, async: true

  import Meerkat.TestHelpers

  alias Meerkat.Git

  describe "parse_name_status/1" do
    test "empty output → empty list" do
      assert Git.parse_name_status("") == []
    end

    test "single added file" do
      out = "A\0src/main.rs\0"

      assert Git.parse_name_status(out) == [
               %{status: :added, file_name: "src/main.rs", old_file_name: nil}
             ]
    end

    test "single deleted file" do
      out = "D\0old.txt\0"

      assert Git.parse_name_status(out) == [
               %{status: :deleted, file_name: "old.txt", old_file_name: nil}
             ]
    end

    test "modified file" do
      out = "M\0lib/foo.ex\0"

      assert Git.parse_name_status(out) == [
               %{status: :modified, file_name: "lib/foo.ex", old_file_name: nil}
             ]
    end

    test "type change (T) is treated as modified" do
      out = "T\0sym\0"

      assert Git.parse_name_status(out) == [
               %{status: :modified, file_name: "sym", old_file_name: nil}
             ]
    end

    test "rename — R<score>\\0<old>\\0<new>\\0" do
      out = "R100\0old/path.rs\0new/path.rs\0"

      assert Git.parse_name_status(out) == [
               %{status: :renamed, file_name: "new/path.rs", old_file_name: "old/path.rs"}
             ]
    end

    test "copy — C<score>\\0<old>\\0<new>\\0 coalesces into rename" do
      out = "C90\0old.rs\0copy.rs\0"

      assert Git.parse_name_status(out) == [
               %{status: :renamed, file_name: "copy.rs", old_file_name: "old.rs"}
             ]
    end

    test "mixed entries preserve order" do
      out = "A\0a.rs\0M\0b.rs\0D\0c.rs\0R80\0old\0new\0"

      assert Git.parse_name_status(out) == [
               %{status: :added, file_name: "a.rs", old_file_name: nil},
               %{status: :modified, file_name: "b.rs", old_file_name: nil},
               %{status: :deleted, file_name: "c.rs", old_file_name: nil},
               %{status: :renamed, file_name: "new", old_file_name: "old"}
             ]
    end

    test "raises on unrecognised status code" do
      out = "X\0weird\0"

      assert_raise RuntimeError, ~r/unrecognised --name-status code/, fn ->
        Git.parse_name_status(out)
      end
    end

    test "paths with spaces survive" do
      out = "M\0src/with space.rs\0"

      assert Git.parse_name_status(out) == [
               %{status: :modified, file_name: "src/with space.rs", old_file_name: nil}
             ]
    end
  end

  describe "parse_multi_file_diff (via test seam)" do
    test "empty output → empty map" do
      assert Git.parse_multi_file_diff_for_test("") == {:ok, %{}}
    end

    test "single-file modified diff is keyed by post-image path" do
      diff = """
      diff --git a/foo.rs b/foo.rs
      index abc..def 100644
      --- a/foo.rs
      +++ b/foo.rs
      @@ -1,3 +1,3 @@
       a
      -b
      +B
       c
      """

      assert {:ok, result} = Git.parse_multi_file_diff_for_test(diff)
      assert Map.keys(result) == ["foo.rs"]
      {hunks, errors} = result["foo.rs"]
      assert errors == []
      assert [hunk] = hunks
      assert hunk =~ "@@ -1,3 +1,3 @@"
    end

    test "rename diff is keyed by NEW path" do
      diff = """
      diff --git a/old/path.rs b/new/path.rs
      similarity index 95%
      rename from old/path.rs
      rename to new/path.rs
      index abc..def 100644
      --- a/old/path.rs
      +++ b/new/path.rs
      @@ -1,3 +1,3 @@
       a
      -b
      +B
       c
      """

      assert {:ok, result} = Git.parse_multi_file_diff_for_test(diff)
      assert Map.keys(result) == ["new/path.rs"]
    end

    test "paths containing ` b/` are unambiguous (regression for header-regex bug)" do
      # If we keyed off `diff --git a/<old> b/<new>` with a greedy
      # regex, `foo b/bar.txt` (post-image path containing ` b/`)
      # would mis-split. The `+++ b/<path>` extractor is line-terminal
      # so this case is unambiguous.
      diff = """
      diff --git a/foo b/bar.txt b/foo b/bar.txt
      index abc..def 100644
      --- a/foo b/bar.txt
      +++ b/foo b/bar.txt
      @@ -1 +1 @@
      -a
      +b
      """

      assert {:ok, result} = Git.parse_multi_file_diff_for_test(diff)
      assert Map.keys(result) == ["foo b/bar.txt"]
    end

    test "deletion diff falls back to pre-image path (`--- a/<path>`)" do
      diff = """
      diff --git a/gone.rs b/gone.rs
      deleted file mode 100644
      index abc..0000000
      --- a/gone.rs
      +++ /dev/null
      @@ -1,3 +0,0 @@
      -a
      -b
      -c
      """

      assert {:ok, result} = Git.parse_multi_file_diff_for_test(diff)
      assert Map.keys(result) == ["gone.rs"]
    end

    test "multi-file output splits per file" do
      diff = """
      diff --git a/a.rs b/a.rs
      --- a/a.rs
      +++ b/a.rs
      @@ -1 +1 @@
      -x
      +X
      diff --git a/b.rs b/b.rs
      --- a/b.rs
      +++ b/b.rs
      @@ -1 +1 @@
      -y
      +Y
      """

      assert {:ok, result} = Git.parse_multi_file_diff_for_test(diff)
      assert Map.keys(result) |> Enum.sort() == ["a.rs", "b.rs"]
    end

    test "a C-quoted path is keyed by the name it stands for" do
      diff =
        ~s(diff --git "a/q\\"uote.txt" "b/q\\"uote.txt"\n) <>
          ~s(index abc..def 100644\n) <>
          ~s(--- "a/q\\"uote.txt"\n) <>
          ~s(+++ "b/q\\"uote.txt"\n) <>
          "@@ -1 +1 @@\n-a\n+b\n"

      assert {:ok, result} = Git.parse_multi_file_diff_for_test(diff)
      assert Map.keys(result) == [~s(q"uote.txt)]
    end

    test "an octal-escaped path is keyed by its bytes" do
      diff =
        ~s(diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"\n) <>
          ~s(--- "a/caf\\303\\251.txt"\n) <>
          ~s(+++ "b/caf\\303\\251.txt"\n) <>
          "@@ -1 +1 @@\n-a\n+b\n"

      {:ok, result} = Git.parse_multi_file_diff_for_test(diff)
      assert Map.keys(result) == ["café.txt"]
    end

    test "a quoted path's escapes stand for the bytes git escaped" do
      diff =
        ~s(diff --git "a/tab\\there\\r\\nlf.txt" "b/tab\\there\\r\\nlf.txt"\n) <>
          ~s(--- "a/tab\\there\\r\\nlf.txt"\n) <>
          ~s(+++ "b/tab\\there\\r\\nlf.txt"\n) <>
          "@@ -1 +1 @@\n-a\n+b\n"

      {:ok, result} = Git.parse_multi_file_diff_for_test(diff)
      assert Map.keys(result) == ["tab\there\r\nlf.txt"]
    end

    test "a backslash short of three octal digits stands for itself" do
      diff =
        ~s(diff --git "a/a\\00n.txt" "b/a\\00n.txt"\n) <>
          ~s(--- "a/a\\00n.txt"\n) <>
          ~s(+++ "b/a\\00n.txt"\n) <>
          "@@ -1 +1 @@\n-a\n+b\n"

      {:ok, result} = Git.parse_multi_file_diff_for_test(diff)
      assert Map.keys(result) == ["a00n.txt"]
    end

    test "one octal digit after the backslash is not an octal escape" do
      diff =
        ~s(diff --git "a/a\\0n0.txt" "b/a\\0n0.txt"\n) <>
          ~s(--- "a/a\\0n0.txt"\n) <>
          ~s(+++ "b/a\\0n0.txt"\n) <>
          "@@ -1 +1 @@\n-a\n+b\n"

      {:ok, result} = Git.parse_multi_file_diff_for_test(diff)
      assert Map.keys(result) == ["a0n0.txt"]
    end

    test "binary and metadata-only blocks need no text markers" do
      for body <- [
            "Binary files a/BUILD.bazel and b/BUILD.bazel differ\n",
            "similarity index 100%\nrename from old.bin\nrename to new.bin\n",
            "old mode 100644\nnew mode 100755\n"
          ] do
        assert Git.parse_multi_file_diff_for_test("diff --git a/file b/file\n" <> body) ==
                 {:ok, %{}}
      end
    end

    test "an unclosed-quoted header on a binary block parses as binary" do
      diff = ~s(diff --git "a/x.txt "b/x.txt\nBinary files "a/x.txt and "b/x.txt differ\n)

      assert Git.parse_multi_file_diff_for_test(diff) == {:ok, %{}}
    end

    test "a renamed binary block needs no same-sided header" do
      diff = """
      diff --git a/old.png b/new.png
      similarity index 90%
      rename from old.png
      rename to new.png
      Binary files a/old.png and b/new.png differ
      """

      assert Git.parse_multi_file_diff_for_test(diff) == {:ok, %{}}
    end

    test "a binary block with no diff --git header is skipped, not crashed on" do
      diff = """
      Binary files a/x.png and b/x.png differ
      diff --git a/y.txt b/y.txt
      --- a/y.txt
      +++ b/y.txt
      @@ -1 +1 @@
      -a
      +b
      """

      assert {:ok, result} = Git.parse_multi_file_diff_for_test(diff)
      assert Map.keys(result) == ["y.txt"]
    end

    test "missing path markers are errors unless the block is metadata-only" do
      for body <- [
            "index abc..def 100644\n",
            "old mode 100644\nnew mode 100755\n@@ -1 +1 @@\n-old\n+new\n"
          ] do
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:error, reason} =
                   Git.parse_multi_file_diff_for_test("diff --git a/file b/file\n" <> body)

          assert reason =~ "couldn't parse staged-diff block"
        end)
      end
    end

    test "malformed blocks return an error as well as a warning" do
      # Capture stderr to confirm the unparseable-block warning fires
      # without polluting the test output.
      capture =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          send(
            self(),
            {:result,
             Git.parse_multi_file_diff_for_test("diff --git malformed\n@@ -1 +1 @@\n-x\n+y\n")}
          )
        end)

      assert_received {:result, result}
      assert {:error, reason} = result
      assert reason =~ "couldn't parse staged-diff block"
      assert capture =~ reason
    end
  end

  defp git_repo(_context) do
    dir = make_git_repo("meerkat-git")
    git(dir, ["config", "user.email", "t@t.t"])
    git(dir, ["config", "user.name", "t"])
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp delete_loose_object!(dir, oid) do
    <<fanout::binary-size(2), rest::binary>> = oid
    File.rm!(Path.join([dir, ".git", "objects", fanout, rest]))
  end

  defp seed_one_of_each_change(dir) do
    File.write!(Path.join(dir, ".gitattributes"), "*.lock linguist-generated\n")
    File.write!(Path.join(dir, "deleted.rs"), "gone\n")
    File.write!(Path.join(dir, "old_name.rs"), "alpha\nbeta\ngamma\ndelta\n")
    File.write!(Path.join(dir, "modified.rs"), "one\ntwo\nthree\n")
    git(dir, ["add", "."])
    git(dir, ["commit", "-qm", "seed"])

    File.write!(Path.join(dir, "added.lock"), "fresh\n")
    git(dir, ["rm", "-q", "deleted.rs"])
    git(dir, ["mv", "old_name.rs", "new_name.rs"])
    File.write!(Path.join(dir, "new_name.rs"), "alpha\nbeta\ngamma\nDELTA\n")
    File.write!(Path.join(dir, "modified.rs"), "one\nTWO\nthree\n")
    git(dir, ["add", "."])
  end

  # Staged maps carry `is_binary`; range maps (no staging concept) omit it.
  defp one_of_each_diffs(effective_oids, with_binary \\ true) do
    diffs = [
      %{
        status: :added,
        file_name: "added.lock",
        old_file_name: nil,
        old_content: "",
        new_content: "fresh\n",
        hunks: ["@@ -0,0 +1,1 @@\n+fresh\n"],
        read_errors: [],
        effective_oid: effective_oids["added.lock"],
        moved_lines: [],
        is_generated: true
      },
      %{
        status: :deleted,
        file_name: "deleted.rs",
        old_file_name: nil,
        old_content: "gone\n",
        new_content: "",
        hunks: ["@@ -1,1 +0,0 @@\n-gone\n"],
        read_errors: [],
        effective_oid: effective_oids["deleted.rs"],
        moved_lines: [],
        is_generated: false
      },
      %{
        status: :modified,
        file_name: "modified.rs",
        old_file_name: nil,
        old_content: "one\ntwo\nthree\n",
        new_content: "one\nTWO\nthree\n",
        hunks: ["@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n"],
        read_errors: [],
        effective_oid: effective_oids["modified.rs"],
        moved_lines: [],
        is_generated: false
      },
      %{
        status: :renamed,
        file_name: "new_name.rs",
        old_file_name: "old_name.rs",
        old_content: "alpha\nbeta\ngamma\ndelta\n",
        new_content: "alpha\nbeta\ngamma\nDELTA\n",
        hunks: ["@@ -1,4 +1,4 @@\n alpha\n beta\n gamma\n-delta\n+DELTA\n"],
        read_errors: [],
        effective_oid: effective_oids["new_name.rs"],
        moved_lines: [],
        is_generated: false
      }
    ]

    if with_binary do
      Enum.map(diffs, &Map.put(&1, :is_binary, false))
    else
      diffs
    end
  end

  describe "current_branch/1" do
    setup :git_repo

    test "names the branch HEAD is on", %{dir: dir} do
      git(dir, ["switch", "-q", "-c", "feature/x"])

      assert Git.current_branch(dir) == "feature/x"
    end
  end

  describe "staged_file_diffs/1" do
    setup :git_repo

    test "an added, a deleted, a renamed-and-edited and a modified file each carry their " <>
           "contents, hunks and staged blob OID",
         %{dir: dir} do
      seed_one_of_each_change(dir)

      effective_oids = %{
        "added.lock" => git(dir, ["rev-parse", ":added.lock"]),
        "deleted.rs" => git(dir, ["rev-parse", "HEAD:deleted.rs"]),
        "modified.rs" => git(dir, ["rev-parse", ":modified.rs"]),
        "new_name.rs" => git(dir, ["rev-parse", ":new_name.rs"])
      }

      assert Git.staged_file_diffs(dir) == {:ok, one_of_each_diffs(effective_oids)}
    end

    test "a modified file stays listed, with the error, when the batched staged diff fails",
         %{dir: dir} do
      File.write!(Path.join(dir, "mod.rs"), "one\n")
      git(dir, ["add", "mod.rs"])
      git(dir, ["commit", "-qm", "seed"])
      File.write!(Path.join(dir, "mod.rs"), "two\n")
      File.write!(Path.join(dir, "added.rs"), "new\n")
      git(dir, ["add", "mod.rs", "added.rs"])
      File.write!(Path.join(dir, "added.rs"), "edited after staging\n")
      added_oid = git(dir, ["rev-parse", ":added.rs"])
      delete_loose_object!(dir, added_oid)

      {result, _stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Git.staged_file_diffs(dir) end)

      diff_error =
        "couldn't compute batched staged diff (git -c core.quotePath=false diff --cached " <>
          "-U3 -w -M --no-textconv --no-ext-diff exited 128: fatal: unable to read #{added_oid}); " <>
          "per-file content may render empty"

      binary_error =
        "couldn't identify staged binary files: git diff --cached --numstat -z -w -M " <>
          "--no-textconv --no-ext-diff exited 128: fatal: unable to read #{added_oid}"

      assert result ==
               {:ok,
                [
                  %{
                    status: :added,
                    is_binary: false,
                    file_name: "added.rs",
                    old_file_name: nil,
                    old_content: "",
                    new_content: "",
                    hunks: [],
                    read_errors: [
                      "couldn't read staged content for added.rs: git show :0:added.rs exited " <>
                        "128: fatal: bad object :0:added.rs",
                      diff_error,
                      binary_error
                    ],
                    effective_oid: added_oid,
                    moved_lines: [],
                    is_generated: false
                  },
                  %{
                    status: :modified,
                    is_binary: false,
                    file_name: "mod.rs",
                    old_file_name: nil,
                    old_content: "one\n",
                    new_content: "two\n",
                    hunks: [],
                    read_errors: [diff_error, binary_error],
                    effective_oid: git(dir, ["rev-parse", ":mod.rs"]),
                    moved_lines: [],
                    is_generated: false
                  }
                ]}
    end

    test "file names that start like an index stage number read their own old and new content",
         %{dir: dir} do
      File.write!(Path.join(dir, "0:foo.txt"), "old zero\n")
      File.write!(Path.join(dir, "1:bar.txt"), "old one\n")
      File.write!(Path.join(dir, "foo.txt"), "unchanged foo\n")
      git(dir, ["add", "."])
      git(dir, ["commit", "-qm", "seed"])
      File.write!(Path.join(dir, "0:foo.txt"), "new zero\n")
      File.write!(Path.join(dir, "1:bar.txt"), "new one\n")
      git(dir, ["add", "."])

      assert Git.staged_file_diffs(dir) ==
               {:ok,
                [
                  %{
                    status: :modified,
                    is_binary: false,
                    file_name: "0:foo.txt",
                    old_file_name: nil,
                    old_content: "old zero\n",
                    new_content: "new zero\n",
                    hunks: ["@@ -1,1 +1,1 @@\n-old zero\n+new zero\n"],
                    read_errors: [],
                    effective_oid: git(dir, ["rev-parse", ":0:0:foo.txt"]),
                    moved_lines: [],
                    is_generated: false
                  },
                  %{
                    status: :modified,
                    is_binary: false,
                    file_name: "1:bar.txt",
                    old_file_name: nil,
                    old_content: "old one\n",
                    new_content: "new one\n",
                    hunks: ["@@ -1,1 +1,1 @@\n-old one\n+new one\n"],
                    read_errors: [],
                    effective_oid: git(dir, ["rev-parse", ":0:1:bar.txt"]),
                    moved_lines: [],
                    is_generated: false
                  }
                ]}
    end

    test "file names git would read as pathspec magic carry their own staged blob OID and " <>
           "no read errors",
         %{dir: dir} do
      File.write!(Path.join(dir, ":(bogus)gone.rs"), "gone\n")
      git(dir, ["add", "."])
      git(dir, ["commit", "-qm", "seed"])
      File.rm!(Path.join(dir, ":(bogus)gone.rs"))
      File.write!(Path.join(dir, ":(bogus)x.rs"), "bogus\n")
      File.write!(Path.join(dir, "plain.rs"), "plain\n")
      git(dir, ["add", "-A"])

      assert Git.staged_file_diffs(dir) ==
               {:ok,
                [
                  %{
                    status: :deleted,
                    is_binary: false,
                    file_name: ":(bogus)gone.rs",
                    old_file_name: nil,
                    old_content: "gone\n",
                    new_content: "",
                    hunks: ["@@ -1,1 +0,0 @@\n-gone\n"],
                    read_errors: [],
                    effective_oid: git(dir, ["rev-parse", "HEAD::(bogus)gone.rs"]),
                    moved_lines: [],
                    is_generated: false
                  },
                  %{
                    status: :added,
                    is_binary: false,
                    file_name: ":(bogus)x.rs",
                    old_file_name: nil,
                    old_content: "",
                    new_content: "bogus\n",
                    hunks: ["@@ -0,0 +1,1 @@\n+bogus\n"],
                    read_errors: [],
                    effective_oid: git(dir, ["rev-parse", "::(bogus)x.rs"]),
                    moved_lines: [],
                    is_generated: false
                  },
                  %{
                    status: :added,
                    is_binary: false,
                    file_name: "plain.rs",
                    old_file_name: nil,
                    old_content: "",
                    new_content: "plain\n",
                    hunks: ["@@ -0,0 +1,1 @@\n+plain\n"],
                    read_errors: [],
                    effective_oid: git(dir, ["rev-parse", ":plain.rs"]),
                    moved_lines: [],
                    is_generated: false
                  }
                ]}
    end
  end

  describe "range_file_diffs/4" do
    setup :git_repo

    test "an added, a deleted, a renamed-and-edited and a modified file each carry their " <>
           "contents and hunks, with no staged blob OID",
         %{dir: dir} do
      seed_one_of_each_change(dir)
      git(dir, ["commit", "-qm", "one of each"])

      assert Git.range_file_diffs(dir, "HEAD~1", "HEAD", :two_dot) ==
               {:ok, one_of_each_diffs(%{}, false)}
    end

    test "file names git would read as pathspec magic carry their own hunks and no read errors",
         %{dir: dir} do
      File.write!(Path.join(dir, ":(bogus)old.rs"), "alpha\nbeta\ngamma\ndelta\n")
      File.write!(Path.join(dir, ":(bogus)x.rs"), "bogus one\n")
      File.write!(Path.join(dir, ":x.rs"), "colon one\n")
      File.write!(Path.join(dir, "x.rs"), "unchanged\n")
      git(dir, ["add", "."])
      git(dir, ["commit", "-qm", "base"])
      File.rm!(Path.join(dir, ":(bogus)old.rs"))
      File.write!(Path.join(dir, ":(bogus)new.rs"), "alpha\nbeta\ngamma\nDELTA\n")
      File.write!(Path.join(dir, ":(bogus)x.rs"), "bogus two\n")
      File.write!(Path.join(dir, ":x.rs"), "colon two\n")
      git(dir, ["add", "-A"])
      git(dir, ["commit", "-qm", "head"])

      assert Git.range_file_diffs(dir, "HEAD~1", "HEAD", :two_dot) ==
               {:ok,
                [
                  %{
                    status: :renamed,
                    file_name: ":(bogus)new.rs",
                    old_file_name: ":(bogus)old.rs",
                    old_content: "alpha\nbeta\ngamma\ndelta\n",
                    new_content: "alpha\nbeta\ngamma\nDELTA\n",
                    hunks: ["@@ -1,4 +1,4 @@\n alpha\n beta\n gamma\n-delta\n+DELTA\n"],
                    read_errors: [],
                    effective_oid: nil,
                    moved_lines: [],
                    is_generated: false
                  },
                  %{
                    status: :modified,
                    file_name: ":(bogus)x.rs",
                    old_file_name: nil,
                    old_content: "bogus one\n",
                    new_content: "bogus two\n",
                    hunks: ["@@ -1,1 +1,1 @@\n-bogus one\n+bogus two\n"],
                    read_errors: [],
                    effective_oid: nil,
                    moved_lines: [],
                    is_generated: false
                  },
                  %{
                    status: :modified,
                    file_name: ":x.rs",
                    old_file_name: nil,
                    old_content: "colon one\n",
                    new_content: "colon two\n",
                    hunks: ["@@ -1,1 +1,1 @@\n-colon one\n+colon two\n"],
                    read_errors: [],
                    effective_oid: nil,
                    moved_lines: [],
                    is_generated: false
                  }
                ]}
    end

    test "a head blob git cannot read leaves the file's content empty and lists both errors",
         %{dir: dir} do
      File.write!(Path.join(dir, "mod.rs"), "one\n")
      git(dir, ["add", "mod.rs"])
      git(dir, ["commit", "-qm", "base"])
      File.write!(Path.join(dir, "mod.rs"), "two\n")
      git(dir, ["commit", "-qam", "head"])
      File.write!(Path.join(dir, "mod.rs"), "edited after committing\n")
      head_oid = git(dir, ["rev-parse", "HEAD:mod.rs"])
      delete_loose_object!(dir, head_oid)

      {result, _stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          Git.range_file_diffs(dir, "HEAD~1", "HEAD", :two_dot)
        end)

      assert result ==
               {:ok,
                [
                  %{
                    status: :modified,
                    file_name: "mod.rs",
                    old_file_name: nil,
                    old_content: "one\n",
                    new_content: "",
                    hunks: [],
                    read_errors: [
                      "couldn't read mod.rs at HEAD: git show HEAD:mod.rs exited 128: " <>
                        "fatal: bad object HEAD:mod.rs",
                      "couldn't compute diff (args: --literal-pathspecs diff -U3 HEAD~1..HEAD " <>
                        "-- mod.rs): git --literal-pathspecs diff -U3 HEAD~1..HEAD -- mod.rs " <>
                        "exited 128: fatal: unable to read #{head_oid}"
                    ],
                    effective_oid: nil,
                    moved_lines: [],
                    is_generated: false
                  }
                ]}
    end
  end

  describe "fetch_pr/3" do
    setup :git_repo

    test "fetches the PR head and the base branch from origin into meerkat-pr refs",
         %{dir: origin} do
      File.write!(Path.join(origin, "base.rs"), "base\n")
      git(origin, ["add", "base.rs"])
      git(origin, ["commit", "-qm", "base"])
      base_sha = git(origin, ["rev-parse", "HEAD"])
      File.write!(Path.join(origin, "feature.rs"), "feature\n")
      git(origin, ["add", "feature.rs"])
      git(origin, ["commit", "-qm", "feature"])
      head_sha = git(origin, ["rev-parse", "HEAD"])
      git(origin, ["update-ref", "refs/pull/7/head", head_sha])
      git(origin, ["update-ref", "refs/heads/release", base_sha])

      local = make_git_repo("meerkat-git-local")
      on_exit(fn -> File.rm_rf!(local) end)
      git(local, ["remote", "add", "origin", origin])

      assert Git.fetch_pr(local, 7, "release") ==
               {:ok, {"refs/meerkat-pr/7/head", "refs/meerkat-pr/7/base"}}

      assert git(local, ["rev-parse", "refs/meerkat-pr/7/head", "refs/meerkat-pr/7/base"]) ==
               "#{head_sha}\n#{base_sha}"
    end

    test "with no origin remote, returns git's error", %{dir: dir} do
      assert {:error,
              "git fetch --force origin +refs/pull/7/head:refs/meerkat-pr/7/head " <>
                "+refs/heads/release:refs/meerkat-pr/7/base exited 128: fatal: 'origin' does " <>
                "not appear to be a git repository\n" <> _} = Git.fetch_pr(dir, 7, "release")
    end
  end

  describe "linguist_generated_many/2" do
    setup :git_repo

    test "answers for a non-ASCII path and a path containing `: `", %{dir: dir} do
      File.write!(Path.join(dir, ".gitattributes"), "*.rs linguist-generated\n")

      assert Git.linguist_generated_many(dir, ["wëird.rs", "a: b.rs", "plain.txt"]) == %{
               "wëird.rs" => {:generated, true},
               "a: b.rs" => {:generated, true},
               "plain.txt" => {:generated, false}
             }
    end

    test "a warning git prints about .gitattributes leaves every path's answer intact",
         %{dir: dir} do
      File.write!(
        Path.join(dir, ".gitattributes"),
        "!*.lock linguist-generated\n*.rs linguist-generated\n"
      )

      assert Git.linguist_generated_many(dir, ["a.rs", "b.txt"]) == %{
               "a.rs" => {:generated, true},
               "b.txt" => {:generated, false}
             }
    end
  end

  describe "lookup_generated/2 (via test seam)" do
    test "a generated answer is used as given, with nothing to report" do
      assert Git.lookup_generated_for_test(%{"a.rs" => {:generated, true}}, "a.rs") == {true, []}

      assert Git.lookup_generated_for_test(%{"a.rs" => {:generated, false}}, "a.rs") ==
               {false, []}
    end

    test "a failed check reads as not-generated and reports the failure" do
      map = %{"a.rs" => {:error, "git blew up"}}

      assert Git.lookup_generated_for_test(map, "a.rs") ==
               {false, ["linguist-generated check failed for a.rs: git blew up"]}
    end

    test "a path git answered nothing for reads as not-generated, silently" do
      assert Git.lookup_generated_for_test(%{}, "a.rs") == {false, []}
    end
  end

  describe "batched lookups with no paths" do
    setup :git_repo

    test "answer without shelling out to git", %{dir: dir} do
      File.rm_rf!(Path.join(dir, ".git"))

      assert Git.linguist_generated_many(dir, []) == %{}
      assert Git.staged_blob_oids_many(dir, []) == {:ok, %{}}
    end
  end

  describe "linguist_generated?/2" do
    setup :git_repo

    test "true for a path marked generated, false for one that is not", %{dir: dir} do
      File.write!(Path.join(dir, ".gitattributes"), "*.rs linguist-generated\n")

      assert Git.linguist_generated?(dir, "a.rs") == true
      assert Git.linguist_generated?(dir, "b.txt") == false
    end
  end

  describe "git_dir/1" do
    setup :git_repo

    test "is the repo's .git directory", %{dir: dir} do
      assert Git.git_dir(dir) == {:ok, Path.join(dir, ".git")}
    end
  end

  describe "git_common_dir/1" do
    setup :git_repo

    test "is the repo's .git directory", %{dir: dir} do
      assert Git.git_common_dir(dir) == {:ok, Path.join(dir, ".git")}
    end
  end

  describe "outside any repo" do
    setup do
      dir = make_tmp_repo("meerkat-git-no-repo")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "staged_files/1 returns git's error", %{dir: dir} do
      assert {:error,
              "git diff --cached --name-status -z -M exited 129: error: unknown option `cached'\n" <>
                _usage} = Git.staged_files(dir)
    end

    test "staged_blob_oids_many/2 returns the lookup error", %{dir: dir} do
      {result, _stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Git.staged_blob_oids_many(dir, ["a.rs"]) end)

      assert result ==
               {:error,
                "couldn't compute batched staged-blob OIDs (git --literal-pathspecs -c " <>
                  "core.quotePath=false ls-files -s -- a.rs exited 128: fatal: not a git " <>
                  "repository (or any of the parent directories): .git); approve guard may " <>
                  "flag files as stale"}
    end

    test "linguist_generated_many/2 maps every path to the lookup error", %{dir: dir} do
      {result, _stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          Git.linguist_generated_many(dir, ["a.rs", "b.txt"])
        end)

      error =
        "couldn't read `linguist-generated` attribute (git check-attr -z linguist-generated " <>
          "-- a.rs b.txt exited 128: fatal: not a git repository (or any of the parent " <>
          "directories): .git). Check your `.gitattributes` syntax."

      assert result == %{"a.rs" => {:error, error}, "b.txt" => {:error, error}}
    end

    test "linguist_generated?/2 is false", %{dir: dir} do
      {result, _stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Git.linguist_generated?(dir, "a.rs") end)

      assert result == false
    end

    test "git_dir/1 returns git's error", %{dir: dir} do
      assert Git.git_dir(dir) ==
               {:error,
                "git rev-parse --git-dir exited 128: fatal: not a git repository (or any of " <>
                  "the parent directories): .git"}
    end

    test "git_common_dir/1 returns git's error", %{dir: dir} do
      assert Git.git_common_dir(dir) ==
               {:error,
                "git rev-parse --git-common-dir exited 128: fatal: not a git repository (or " <>
                  "any of the parent directories): .git"}
    end
  end
end

defmodule Meerkat.GitMeerkatDirTest do
  use ExUnit.Case, async: false

  import Meerkat.TestHelpers

  alias Meerkat.Git

  setup do
    dir = make_git_repo("meerkat-git-meerkat-dir")
    previous = Application.fetch_env(:meerkat, :meerkat_dir)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:meerkat, :meerkat_dir, value)
        :error -> Application.delete_env(:meerkat, :meerkat_dir)
      end

      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  test "with no cached value, meerkat_dir/1 is meerkat-precommit under the gitdir",
       %{dir: dir} do
    Application.delete_env(:meerkat, :meerkat_dir)

    # `git rev-parse` answers with symlinks resolved, which on macOS
    # makes every path under `/var` come back under `/private/var`.
    root = File.cd!(dir, &File.cwd!/0)

    assert Git.meerkat_dir(dir) == Path.join([root, ".git", "meerkat-precommit"])
  end

  test "with no cached value, meerkat_dir/1 from a subdirectory is the repo's own", %{dir: dir} do
    Application.delete_env(:meerkat, :meerkat_dir)
    sub = Path.join([dir, "services", "api"])
    File.mkdir_p!(sub)

    assert Git.meerkat_dir(sub) == Git.meerkat_dir(dir)
  end

  test "with no cached value and no repo, meerkat_dir/1 is meerkat-precommit under <dir>/.git" do
    Application.delete_env(:meerkat, :meerkat_dir)
    not_a_repo = make_tmp_repo("meerkat-git-meerkat-dir-no-repo")
    on_exit(fn -> File.rm_rf!(not_a_repo) end)

    assert Git.meerkat_dir(not_a_repo) == Path.join([not_a_repo, ".git", "meerkat-precommit"])
  end

  test "a cached value is what meerkat_dir/1 returns", %{dir: dir} do
    cached = Path.join(dir, "cached-meerkat-dir")
    Application.put_env(:meerkat, :meerkat_dir, cached)

    assert Git.meerkat_dir(dir) == cached
  end
end
