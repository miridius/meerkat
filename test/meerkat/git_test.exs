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

  # One repo, on `feature/x`, built once from literal files; tests only
  # read it, and a failure git would report comes from `stub_git`. HEAD
  # holds every staged scenario's base, and each scenario's index file
  # holds HEAD with that scenario's files staged in place of its base, so
  # a staged review through it shows only that scenario. Each range
  # scenario is a pair of commits.
  @staged %{
    "one-of-each" => {
      %{
        "deleted.rs" => "gone\n",
        "old_name.rs" => "alpha\nbeta\ngamma\ndelta\n",
        "modified.rs" => "one\ntwo\nthree\n"
      },
      %{
        "added.lock" => "fresh\n",
        "new_name.rs" => "alpha\nbeta\ngamma\nDELTA\n",
        "modified.rs" => "one\nTWO\nthree\n"
      }
    },
    "line-counts" => {
      %{"f.sql" => "-- note\nb\nc\nd\ne\nf\ng\nh\ni\nj\nlast"},
      %{"f.sql" => "++ note\nx\nb\nc  \nd\ne\nf\ng\nh\ni\nj\nlast!"}
    },
    "failed-diff" => {%{"mod.rs" => "one\n"}, %{"mod.rs" => "two\n", "added.rs" => "new\n"}},
    "stage-names" => {
      %{"0:foo.txt" => "old zero\n", "1:bar.txt" => "old one\n", "foo.txt" => "unchanged foo\n"},
      %{"0:foo.txt" => "new zero\n", "1:bar.txt" => "new one\n", "foo.txt" => "unchanged foo\n"}
    },
    "magic" => {
      %{":(bogus)gone.rs" => "gone\n"},
      %{":(bogus)x.rs" => "bogus\n", "plain.rs" => "plain\n"}
    }
  }

  setup_all do
    template =
      fixture_template("meerkat-git-template", fn dir ->
        repo = Path.join(dir, "repo")
        File.mkdir_p!(repo)
        git(repo, ["init", "-q", "--initial-branch=feature/x"])
        git(repo, ["config", "diff.suppressBlankEmpty", "true"])
        git(repo, ["remote", "add", "origin", repo])
        File.write!(Path.join(repo, ".gitattributes"), "*.lock linguist-generated\n")
        File.mkdir_p!(Path.join(repo, "attrs"))
        File.write!(Path.join(repo, "attrs/.gitattributes"), "*.rs linguist-generated\n")
        File.mkdir_p!(Path.join(repo, "warn"))

        File.write!(
          Path.join(repo, "warn/.gitattributes"),
          "!*.lock linguist-generated\n*.rs linguist-generated\n"
        )

        File.mkdir_p!(Path.join(dir, "no-repo/.git"))

        bases = @staged |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.reduce(&Map.merge/2)

        staged =
          for {name, {base, staged}} <- @staged do
            {"refs/heads/staged/#{name}", bases |> Map.drop(Map.keys(base)) |> Map.merge(staged)}
          end

        moved = "moved line one\nmoved line two\nmoved line three\n"
        release = %{"base.rs" => "base\n"}

        import_commits(
          repo,
          [{"refs/heads/feature/x", bases} | staged] ++
            [
              {"refs/heads/blank-base", %{"a.txt" => "top\n\n" <> moved <> "bottom\n"}},
              {"refs/heads/blank-tip", %{"a.txt" => "top\n\nbottom\n", "b.txt" => moved}},
              {"refs/heads/magic-base",
               %{
                 "x.rs" => "unchanged\n",
                 ":(bogus)old.rs" => "alpha\nbeta\ngamma\ndelta\n",
                 ":(bogus)x.rs" => "bogus one\n",
                 ":x.rs" => "colon one\n"
               }},
              {"refs/heads/magic-tip",
               %{
                 "x.rs" => "unchanged\n",
                 ":(bogus)new.rs" => "alpha\nbeta\ngamma\nDELTA\n",
                 ":(bogus)x.rs" => "bogus two\n",
                 ":x.rs" => "colon two\n"
               }},
              {"refs/heads/mod-base", %{"mod.rs" => "one\n"}},
              {"refs/heads/mod-tip", %{"mod.rs" => "two\n"}},
              {"refs/heads/release", release},
              # Over `release`, as the parentless commits of one tree are one commit.
              {"refs/pull/7/head", release},
              {"refs/pull/7/head", Map.put(release, "feature.rs", "feature\n")}
            ]
        )

        for name <- Map.keys(@staged) do
          read_tree(repo, "staged/#{name}", Path.join(repo, ".git/index-#{name}"))
        end
      end)

    {:ok, repo: Path.join(template, "repo"), no_repo: Path.join(template, "no-repo")}
  end

  # `Git.staged_file_diffs/1` through the index file of the scenario `name`.
  defp staged_file_diffs(repo, name) do
    Git.with_index(repo, Path.join(repo, ".git/index-#{name}"), fn ->
      Git.staged_file_diffs(repo)
    end)
  end

  defp one_of_each_diffs(effective_oids) do
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
        additions: 1,
        deletions: 0,
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
        additions: 0,
        deletions: 1,
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
        additions: 1,
        deletions: 1,
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
        additions: 1,
        deletions: 1,
        is_generated: false
      }
    ]

    Enum.map(diffs, &Map.put(&1, :is_binary, false))
  end

  describe "current_branch/1" do
    test "names the branch HEAD is on", %{repo: repo} do
      assert Git.current_branch(repo) == "feature/x"
    end
  end

  describe "staged_file_diffs/1" do
    test "an added, a deleted, a renamed-and-edited and a modified file each carry their " <>
           "contents, hunks and staged blob OID",
         %{repo: repo} do
      effective_oids = %{
        "added.lock" => blob_oid("fresh\n"),
        "deleted.rs" => blob_oid("gone\n"),
        "modified.rs" => blob_oid("one\nTWO\nthree\n"),
        "new_name.rs" => blob_oid("alpha\nbeta\ngamma\nDELTA\n")
      }

      assert staged_file_diffs(repo, "one-of-each") == {:ok, one_of_each_diffs(effective_oids)}
    end

    test "line counts cover every shown hunk, but not hunk headers, no-newline markers or " <>
           "whitespace-only edits",
         %{repo: repo} do
      assert {:ok, [%{hunks: [_, _ | _], additions: 3, deletions: 2}]} =
               staged_file_diffs(repo, "line-counts")
    end

    # The answers git gives when the added file's staged blob is missing.
    test "a modified file stays listed, with the error, when the batched staged diff fails",
         %{repo: repo} do
      added_oid = blob_oid("new\n")
      unreadable = {"fatal: unable to read #{added_oid}\n", 128}

      stub_git(fn
        [_git, "show", ":0:added.rs"] -> {"fatal: bad object :0:added.rs\n", 128}
        argv -> if "-U3" in argv or "--numstat" in argv, do: unreadable, else: :real
      end)

      {result, _stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> staged_file_diffs(repo, "failed-diff") end)

      diff_error =
        "couldn't compute batched staged diff (git -c core.quotePath=false " <>
          "--literal-pathspecs diff --cached " <>
          "-U3 --diff-filter=u -w -M --no-textconv --no-ext-diff exited 128: fatal: unable to read #{added_oid}); " <>
          "per-file content may render empty"

      binary_error =
        "couldn't identify binary files: git diff --cached --numstat -z -w -M " <>
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
                    additions: 0,
                    deletions: 0,
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
                    effective_oid: blob_oid("two\n"),
                    moved_lines: [],
                    additions: 0,
                    deletions: 0,
                    is_generated: false
                  }
                ]}
    end

    test "file names that start like an index stage number read their own old and new content",
         %{repo: repo} do
      assert staged_file_diffs(repo, "stage-names") ==
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
                    effective_oid: blob_oid("new zero\n"),
                    moved_lines: [],
                    additions: 1,
                    deletions: 1,
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
                    effective_oid: blob_oid("new one\n"),
                    moved_lines: [],
                    additions: 1,
                    deletions: 1,
                    is_generated: false
                  }
                ]}
    end

    test "file names git would read as pathspec magic carry their own staged blob OID and " <>
           "no read errors",
         %{repo: repo} do
      assert staged_file_diffs(repo, "magic") ==
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
                    effective_oid: blob_oid("gone\n"),
                    moved_lines: [],
                    additions: 0,
                    deletions: 1,
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
                    effective_oid: blob_oid("bogus\n"),
                    moved_lines: [],
                    additions: 1,
                    deletions: 0,
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
                    effective_oid: blob_oid("plain\n"),
                    moved_lines: [],
                    additions: 1,
                    deletions: 0,
                    is_generated: false
                  }
                ]}
    end
  end

  describe "range_file_diffs/4" do
    test "an added, a deleted, a renamed-and-edited and a modified file each carry their " <>
           "contents and hunks, with no staged blob OID",
         %{repo: repo} do
      assert Git.range_file_diffs(repo, "feature/x", "staged/one-of-each", :two_dot) ==
               {:ok, one_of_each_diffs(%{})}
    end

    test "under diff.suppressBlankEmpty an empty blank context line still numbers moved lines",
         %{repo: repo} do
      {:ok, [a, _b]} = Git.range_file_diffs(repo, "blank-base", "blank-tip", :two_dot)

      assert a.hunks == [
               "@@ -1,6 +1,3 @@\n top\n\n-moved line one\n-moved line two\n-moved line three\n bottom\n"
             ]

      assert [%{side: :old, line_start: 3, line_end: 5, to_file: "b.txt"}] = a.moved_lines
    end

    test "file names git would read as pathspec magic carry their own hunks and no read errors",
         %{repo: repo} do
      assert Git.range_file_diffs(repo, "magic-base", "magic-tip", :two_dot) ==
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
                    is_binary: false,
                    moved_lines: [],
                    additions: 1,
                    deletions: 1,
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
                    is_binary: false,
                    moved_lines: [],
                    additions: 1,
                    deletions: 1,
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
                    is_binary: false,
                    moved_lines: [],
                    additions: 1,
                    deletions: 1,
                    is_generated: false
                  }
                ]}
    end

    # The answers git gives when the tip commit's blob is missing.
    test "a head blob git cannot read leaves the file's content empty and lists every error",
         %{repo: repo} do
      head_oid = blob_oid("two\n")
      unreadable = {"fatal: unable to read #{head_oid}\n", 128}

      stub_git(fn
        [_git, "show", "mod-tip:mod.rs"] -> {"fatal: bad object mod-tip:mod.rs\n", 128}
        argv -> if "-U3" in argv or "--numstat" in argv, do: unreadable, else: :real
      end)

      {result, _stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          Git.range_file_diffs(repo, "mod-base", "mod-tip", :two_dot)
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
                      "couldn't read mod.rs at mod-tip: git show mod-tip:mod.rs exited 128: " <>
                        "fatal: bad object mod-tip:mod.rs",
                      "couldn't compute diff (args: --literal-pathspecs diff -U3 " <>
                        "mod-base..mod-tip -- mod.rs): git --literal-pathspecs diff -U3 " <>
                        "mod-base..mod-tip -- mod.rs exited 128: fatal: unable to read #{head_oid}",
                      "couldn't identify binary files: git diff --numstat -z mod-base..mod-tip " <>
                        "exited 128: fatal: unable to read #{head_oid}"
                    ],
                    effective_oid: nil,
                    is_binary: false,
                    moved_lines: [],
                    additions: 0,
                    deletions: 0,
                    is_generated: false
                  }
                ]}
    end
  end

  describe "fetch_pr/3" do
    # The repo is its own origin. Writes only `refs/meerkat-pr/7/*`, which
    # no other test reads.
    test "fetches the PR head and the base branch from origin into meerkat-pr refs",
         %{repo: repo} do
      assert Git.fetch_pr(repo, 7, "release") ==
               {:ok, {"refs/meerkat-pr/7/head", "refs/meerkat-pr/7/base"}}

      assert git(repo, ["rev-parse", "refs/meerkat-pr/7/head", "refs/meerkat-pr/7/base"]) ==
               git(repo, ["rev-parse", "refs/pull/7/head", "release"])
    end

    test "with no origin remote, returns git's error", %{repo: repo} do
      stub_git("fetch", {"fatal: 'origin' does not appear to be a git repository\n", 128})

      assert {:error,
              "git fetch --force origin +refs/pull/7/head:refs/meerkat-pr/7/head " <>
                "+refs/heads/release:refs/meerkat-pr/7/base exited 128: fatal: 'origin' does " <>
                "not appear to be a git repository"} = Git.fetch_pr(repo, 7, "release")
    end
  end

  describe "linguist_generated_many/2" do
    test "answers for a non-ASCII path and a path containing `: `", %{repo: repo} do
      assert Git.linguist_generated_many(repo, ["attrs/wëird.rs", "attrs/a: b.rs", "plain.txt"]) ==
               %{
                 "attrs/wëird.rs" => {:generated, true},
                 "attrs/a: b.rs" => {:generated, true},
                 "plain.txt" => {:generated, false}
               }
    end

    test "a warning git prints about .gitattributes leaves every path's answer intact",
         %{repo: repo} do
      assert Git.linguist_generated_many(repo, ["warn/a.rs", "warn/b.txt"]) == %{
               "warn/a.rs" => {:generated, true},
               "warn/b.txt" => {:generated, false}
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
    test "answer without shelling out to git", %{no_repo: dir} do
      stub_git(fn argv -> flunk("ran #{inspect(argv)}") end)

      assert Git.linguist_generated_many(dir, []) == %{}
      assert Git.staged_blob_oids_many(dir, []) == {:ok, %{}}
    end
  end

  describe "linguist_generated?/2" do
    test "true for a path marked generated, false for one that is not", %{repo: repo} do
      assert Git.linguist_generated?(repo, "attrs/a.rs") == true
      assert Git.linguist_generated?(repo, "attrs/b.txt") == false
    end
  end

  describe "git_dir/1" do
    test "is the repo's .git directory", %{repo: repo} do
      assert Git.git_dir(repo) == {:ok, Path.join(repo, ".git")}
    end
  end

  describe "git_common_dir/1" do
    test "is the repo's .git directory", %{repo: repo} do
      assert Git.git_common_dir(repo) == {:ok, Path.join(repo, ".git")}
    end
  end

  describe "outside any repo" do
    setup %{no_repo: dir}, do: {:ok, dir: dir}

    test "staged_files/1 returns git's error", %{dir: dir} do
      assert {:error,
              "git diff --cached --name-status -z -M --diff-filter=u exited 129: error: unknown option `cached'\n" <>
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
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers

  alias Meerkat.Git

  # One repo and one dir that is none, built once; tests only read them.
  setup_all do
    template =
      fixture_template("meerkat-git-meerkat-dir", fn dir ->
        git(dir, ["init", "-q", "repo"])
        File.mkdir_p!(Path.join(dir, "repo/services/api"))
        File.mkdir_p!(Path.join(dir, "no-repo/.git"))
      end)

    {:ok, dir: Path.join(template, "repo"), not_a_repo: Path.join(template, "no-repo")}
  end

  setup do
    previous = Application.fetch_env(:meerkat, :meerkat_dir)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:meerkat, :meerkat_dir, value)
        :error -> Application.delete_env(:meerkat, :meerkat_dir)
      end
    end)
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
    assert Git.meerkat_dir(Path.join([dir, "services", "api"])) == Git.meerkat_dir(dir)
  end

  test "with no cached value and no repo, meerkat_dir/1 is meerkat-precommit under <dir>/.git",
       %{not_a_repo: not_a_repo} do
    Application.delete_env(:meerkat, :meerkat_dir)
    assert Git.meerkat_dir(not_a_repo) == Path.join([not_a_repo, ".git", "meerkat-precommit"])
  end

  test "a cached value is what meerkat_dir/1 returns", %{dir: dir} do
    cached = Path.join(dir, "cached-meerkat-dir")
    Application.put_env(:meerkat, :meerkat_dir, cached)

    assert Git.meerkat_dir(dir) == cached
  end
end
