defmodule Meerkat.GitTest do
  use ExUnit.Case, async: true

  alias Meerkat.Git

  describe "language_for/1" do
    test "maps common extensions to shiki ids" do
      assert Git.language_for("foo.rs") == "rust"
      assert Git.language_for("foo.ts") == "typescript"
      assert Git.language_for("foo.tsx") == "tsx"
      assert Git.language_for("foo.js") == "javascript"
      assert Git.language_for("foo.jsx") == "jsx"
      assert Git.language_for("foo.ex") == "elixir"
      assert Git.language_for("foo.exs") == "elixir"
      assert Git.language_for("foo.py") == "python"
      assert Git.language_for("foo.go") == "go"
      assert Git.language_for("foo.java") == "java"
      assert Git.language_for("foo.rb") == "ruby"
      assert Git.language_for("foo.css") == "css"
      assert Git.language_for("foo.html") == "html"
      assert Git.language_for("foo.json") == "json"
      assert Git.language_for("foo.yaml") == "yaml"
      assert Git.language_for("foo.yml") == "yaml"
      assert Git.language_for("foo.md") == "markdown"
      assert Git.language_for("foo.sh") == "bash"
      assert Git.language_for("foo.svelte") == "svelte"
    end

    test "extension-less file → plaintext" do
      assert Git.language_for("Makefile") == "plaintext"
      assert Git.language_for("README") == "plaintext"
    end

    test "unknown extension falls through unchanged" do
      assert Git.language_for("foo.clj") == "clj"
      assert Git.language_for("foo.zig") == "zig"
    end

    test "extension lookup is case-insensitive" do
      assert Git.language_for("Foo.RS") == "rust"
      assert Git.language_for("README.MD") == "markdown"
    end
  end

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
      assert Git.parse_multi_file_diff_for_test("") == %{}
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

      result = Git.parse_multi_file_diff_for_test(diff)
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

      result = Git.parse_multi_file_diff_for_test(diff)
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

      result = Git.parse_multi_file_diff_for_test(diff)
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

      result = Git.parse_multi_file_diff_for_test(diff)
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

      result = Git.parse_multi_file_diff_for_test(diff)
      assert Map.keys(result) |> Enum.sort() == ["a.rs", "b.rs"]
    end

    test "block with no +++ or --- marker is dropped (and produces a warning)" do
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
      assert result == %{}
      assert capture =~ "couldn't parse staged-diff block"
    end
  end
end
