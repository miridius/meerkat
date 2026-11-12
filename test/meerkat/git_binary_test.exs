defmodule Meerkat.GitBinaryTest do
  use Meerkat.Case, async: false

  alias Meerkat.Git

  import Meerkat.TestHelpers,
    only: [
      import_commit: 3,
      import_commits: 2,
      read_tree: 3,
      intercept_git: 3,
      git: 2,
      stub_git: 1,
      stub_git: 2
    ]

  # Built once from literal files; tests only read the repos, and a
  # failure comes from `stub_git`. `staged` holds the scenarios of several
  # tests, each in its own dir, with contents no other scenario shares so
  # renames pair only within one. Its own index stages them all; the
  # `submodule` index file stages that dir's change alone. Range reviews
  # compare its branches. `unborn`'s HEAD has no commit; it has an index file for
  # each of its scenarios.
  setup_all do
    template =
      Meerkat.TestHelpers.fixture_template("meerkat-binary-template", fn dir ->
        build_staged(Path.join(dir, "staged"))
        build_unborn(Path.join(dir, "unborn"))
      end)

    staged = Path.join(template, "staged")

    # The staged -M must find renames without the config's help.
    System.put_env(%{
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_KEY_0" => "diff.renames",
      "GIT_CONFIG_VALUE_0" => "false"
    })

    {result, stderr} =
      try do
        ExUnit.CaptureIO.with_io(:stderr, fn -> Git.staged_file_diffs(staged) end)
      after
        Meerkat.TestHelpers.put_git_config_env()
      end

    {:ok, files} = result

    {:ok,
     staged: staged,
     staged_files: files,
     by_name: Map.new(files, &{&1.file_name, &1}),
     staged_stderr: stderr,
     unborn: Path.join(template, "unborn")}
  end

  defp init(dir) do
    File.mkdir_p!(dir)
    git(dir, ["init", "-q", "--initial-branch=main"])
  end

  # The staged review of the repo `dir` through its index file `name`.
  defp staged_in(dir, name) do
    Git.with_index(dir, Path.join(dir, ".git/" <> name), fn -> Git.staged_file_diffs(dir) end)
  end

  defp lines(prefix), do: Enum.map_join(1..20, &"#{prefix} #{&1}\n")

  defp build_staged(dir) do
    init(dir)
    first = import_commit(dir, "refs/heads/first", %{"first.txt" => "first\n"})

    attributes = %{
      ".gitattributes" => "*.gen -diff\ncr.gen? -diff\n",
      "kinds/.gitattributes" => "macro.gen binary\n",
      "renames/.gitattributes" => "*.bin binary\n",
      "mixed/.gitattributes" => "generated.blob linguist-generated=true\n",
      "submodule/.gitattributes" => "* -diff\n"
    }

    base = %{
      "bazel/BUILD.bazel" => "a\nb\nc\n",
      "bazel/query.clj" => "(old-query)\n",
      "bazel/spaces.txt" => "old text\n",
      "kinds/nul.gen" => "nul old\n",
      "kinds/macro.gen" => "macro old\n",
      "kinds/late-nul.gen" => "late old\n",
      "kinds/last-nul.gen" => "last old\n",
      "kinds/latin1.gen" => "latin old\n",
      "renames/plain.txt" => lines("plain"),
      "renames/marked.gen" => lines("marked"),
      "renames/out.gen" => lines("out"),
      "renames/was.bin" => lines("was"),
      "deleted/gone.gen" => "gone one\ngone two\n",
      "oldnul/a.gen" => "oldnul" <> <<0>>,
      "space/space.gen" => "keep\nspace here\n",
      "rename/old.gen" => lines("rename"),
      "binary/old b/name with spaces.bin" => <<0, 255, 1>>,
      "binary/gone.blob" => <<0, 254, 2>>,
      "mixed/gone.blob" => "old deleted" <> <<0>>,
      "mixed/old.blob" => "renamed content" <> <<0>>,
      "mixed/query.clj" => "(old-mixed-query)\n",
      "submodule/z.gen" => "old\n",
      # One submodule commit this repo's objects lack, and one they hold.
      "submodule/a.sub" => {:gitlink, String.duplicate("1", 40)},
      "submodule/b.sub" => {:gitlink, first}
    }

    staged = %{
      # A text file git calls binary only through -diff.
      "bazel/BUILD.bazel" => "a\nB\nc\nd\n",
      "bazel/query.clj" => "(new-query)\n",
      "bazel/spaces.txt" => "old   text\n",
      # The page's JSON can't carry bytes that aren't UTF-8.
      "kinds/latin1.gen" => "caf" <> <<0xE9>> <> "\n",
      "kinds/nul.gen" => "new" <> <<0>> <> "\n",
      "kinds/macro.gen" => "macro new\n",
      # Meerkat's NUL check, like git's, reads only the first 8000 bytes.
      "kinds/late-nul.gen" => String.duplicate("l", 8000) <> <<0>>,
      "kinds/last-nul.gen" => String.duplicate("t", 7999) <> <<0>>,
      "renames/plain.gen" => lines("plain"),
      "renames/marked.bin" => lines("marked"),
      "renames/out.txt" => lines("out") <> "extra\n",
      "renames/was.gen" => lines("was") <> "extra\n",
      "oldnul/a.gen" => "oldnul new\n",
      "big/big.gen" => String.duplicate("x", 5 * 1024 * 1024) <> "\nend\n",
      "space/space.gen" => "keep\nspace  here\nadded\n",
      # With a bare `:` prefix, `1:a.gen`'s index side would read as merge
      # stage 1 of `a.gen`; the probe must use `:0:`.
      "1:a.gen" => "stage-like\n",
      "index/text.gen" => "staged\n",
      "index/nul.gen" => "staged" <> <<0>>,
      "fail/a.gen" => "fail a\n",
      "fail/b.gen" => "fail b\n",
      "names/new\nline.gen" => "newline\n",
      # cat-file would read `:0:names/cr.gen`, this blob, for `:0:names/cr.gen\r`.
      "names/cr.gen" => "cr\n",
      "names/cr.gen\r" => "nul" <> <<0>>,
      "names/plain.gen" => "names plain\n",
      # Git reads a CR inside a name as it is.
      "names/mid\rcr.gen" => "mid cr\n",
      "patch/a.gen" => "patch a\n",
      "patch/logo.bin" => <<0, 1>>,
      "patch/plain.txt" => "patch plain\n",
      "rename/new.gen" => lines("rename") <> "extra\n",
      "binary/new b/name with spaces.bin" => <<0, 255, 1>>,
      "mixed/new.blob" => "renamed content" <> <<0>>,
      "mixed/query.clj" => "(new-mixed-query)\n",
      "mixed/added.md" => "# Binary" <> <<0>>,
      "mixed/generated.blob" => "generated binary content" <> <<0>>
    }

    gone =
      ~w(renames/plain.txt renames/marked.gen renames/out.gen renames/was.bin
         deleted/gone.gen rename/old.gen binary/gone.blob mixed/gone.blob mixed/old.blob) ++
        ["binary/old b/name with spaces.bin"]

    submodule = %{
      "submodule/z.gen" => "new\n",
      "submodule/a.sub" => "now a file\n",
      "submodule/b.sub" => "now a file\n"
    }

    base = Map.merge(attributes, base)

    # `tip`, compared with `base` for two-dot reviews; `topic`, and
    # `main-moved` past the fork, both branches off `base`, for a
    # three-dot one. The work tree's `.gitattributes` marks `*.gen` -diff.
    range = %{
      "gen/a.gen" => "one\n",
      "gen/nul.gen" => "nul one\n",
      "gen/moved.gen" => lines("line"),
      "bin/logo.png" => <<0, 255, 1>>,
      "bin/moved.bin" => <<0, 253, 3>>,
      "bin/text.txt" => "old\n",
      "fork.gen" => "fork one\n"
    }

    tip = %{
      "gen/a.gen" => "two\n",
      "gen/nul.gen" => <<0>>,
      "gen/renamed.gen" => lines("line") <> "extra\n",
      "bin/logo.png" => <<0, 254, 2>>,
      "bin/renamed.bin" => <<0, 253, 3>>,
      "bin/new.bin" => <<0, 252>>,
      "bin/text.txt" => "new\n"
    }

    import_commits(dir, [
      {"refs/heads/main", base},
      {"refs/heads/staged", base |> Map.drop(gone) |> Map.merge(staged)},
      {"refs/heads/submodule", Map.merge(base, submodule)},
      {"refs/heads/base", range},
      {"refs/heads/tip", range |> Map.drop(~w(gen/moved.gen bin/moved.bin)) |> Map.merge(tip)},
      # Over `base`, as the parentless commits of one tree are one commit.
      {"refs/heads/main-moved", range},
      {"refs/heads/main-moved", %{range | "fork.gen" => "fork one" <> <<0>>}},
      {"refs/heads/topic", range},
      {"refs/heads/topic", %{range | "fork.gen" => "fork two\n"}}
    ])

    git(dir, ["reset", "-q", "--hard"])
    read_tree(dir, "staged", nil)
    read_tree(dir, "submodule", Path.join(dir, ".git/submodule"))
    # Tests init with no template, so git makes no info/ dir for its attributes.
    File.mkdir_p!(Path.join(dir, ".git/info"))
    File.write!(Path.join(dir, ".git/info/attributes"), "/bazel/BUILD.bazel -diff\n")
    File.mkdir_p!(Path.join(dir, "index"))
    File.write!(Path.join(dir, "index/text.gen"), "worktree" <> <<0>>)
    File.write!(Path.join(dir, "index/nul.gen"), "worktree\n")
  end

  # `plain` holds no -diff file, `text` no binary file.
  defp build_unborn(dir) do
    init(dir)

    import_commits(dir, [
      {"refs/meerkat-test/plain", %{"a.bin" => <<0, 255>>, "a.txt" => "text\n"}},
      {"refs/meerkat-test/text", %{"a.txt" => "text\n"}}
    ])

    for name <- ~w(plain text),
        do: read_tree(dir, "refs/meerkat-test/#{name}", Path.join(dir, ".git/" <> name))
  end

  test "a text file git calls binary only through -diff shows its lines", %{
    staged: staged,
    by_name: by_name,
    staged_stderr: stderr
  } do
    assert git(staged, ["diff", "--cached", "--numstat"]) =~ "-\t-\tbazel/BUILD.bazel"

    bazel = by_name["bazel/BUILD.bazel"]
    refute bazel.is_binary
    assert Enum.join(bazel.hunks) =~ "-b\n+B\n c\n+d"
    assert {bazel.additions, bazel.deletions} == {2, 1}
    assert bazel.new_content == "a\nB\nc\nd\n"
    assert bazel.read_errors == []
    refute by_name["bazel/query.clj"].is_binary
    assert Enum.join(by_name["bazel/query.clj"].hunks) =~ "+(new-query)"
    # Whitespace-only under -w.
    refute Map.has_key?(by_name, "bazel/spaces.txt")
    refute stderr =~ "couldn't parse"
  end

  test "a -diff file stays binary when its content or the binary macro says so", %{
    by_name: by_name
  } do
    assert_binary(by_name["kinds/nul.gen"], :modified)
    assert_binary(by_name["kinds/macro.gen"], :modified)
    assert_binary(by_name["kinds/last-nul.gen"], :modified)
    assert_binary(by_name["kinds/latin1.gen"], :modified)
    refute by_name["kinds/late-nul.gen"].is_binary
  end

  test "a text file renamed into or out of -diff shows its lines, and one renamed into or " <>
         "out of the binary macro stays binary",
       %{staged: staged, by_name: by_name} do
    assert git(staged, ["diff", "--cached", "--numstat", "-M"]) =~
             "-\t-\trenames/{out.gen => out.txt}"

    refute by_name["renames/plain.gen"].is_binary
    assert by_name["renames/plain.gen"].new_content =~ "plain 20"
    refute by_name["renames/out.txt"].is_binary
    assert Enum.join(by_name["renames/out.txt"].hunks) =~ "+extra"
    assert_binary(by_name["renames/marked.bin"], :renamed)
    assert_binary(by_name["renames/was.gen"], :renamed)
  end

  test "a deleted -diff text file shows its removed lines", %{by_name: by_name} do
    file = by_name["deleted/gone.gen"]
    assert file.status == :deleted
    refute file.is_binary
    assert {file.additions, file.deletions} == {0, 2}
  end

  test "a -diff file whose old side holds a NUL stays binary", %{by_name: by_name} do
    assert_binary(by_name["oldnul/a.gen"], :modified)
  end

  test "an added -diff text file shows its lines whatever its size", %{by_name: by_name} do
    big = by_name["big/big.gen"]
    refute big.is_binary
    assert {big.additions, big.deletions} == {2, 0}
    assert Enum.join(big.hunks) =~ "+end"
  end

  test "a staged -diff text file ignores whitespace changes, and one named like a stage reads",
       %{by_name: by_name} do
    space = by_name["space/space.gen"]
    refute by_name["1:a.gen"].is_binary
    refute space.is_binary
    assert Enum.join(space.hunks) =~ "+added"
    refute Enum.join(space.hunks) =~ "-space here"
  end

  test "a staged -diff file is judged by its index content, not the worktree's", %{
    by_name: by_name
  } do
    text = by_name["index/text.gen"]
    refute text.is_binary
    assert Enum.join(text.hunks) =~ "+staged"
    assert_binary(by_name["index/nul.gen"], :added)
  end

  for {failure, answer} <- [
        {"fails", {"", 1}},
        {"is cut short", {"abc123 blob 99\nshort\n", 0}},
        {"answers out of form", {"garbage\n", 0}}
      ] do
    test "a -diff file stays binary when its content read #{failure}", %{staged: staged} do
      stub_git("sh", unquote(Macro.escape(answer)))

      by_name = staged_by_name(staged)
      assert_binary(by_name["fail/a.gen"], :added)
      assert_binary(by_name["fail/b.gen"], :added)
    end
  end

  test "a -diff text file whose name holds a newline or a carriage return stays binary", %{
    by_name: by_name
  } do
    assert by_name["names/new\nline.gen"].is_binary
    assert by_name["names/cr.gen\r"].is_binary
    refute by_name["names/cr.gen"].is_binary
    refute by_name["names/mid\rcr.gen"].is_binary
    refute by_name["names/plain.gen"].is_binary
  end

  test "a submodule side stays binary and leaves later -diff files' probes intact", %{
    staged: dir
  } do
    assert {:ok, files} = staged_in(dir, "submodule")
    by_name = Map.new(files, &{&1.file_name, &1})
    assert by_name["submodule/a.sub"].is_binary
    assert by_name["submodule/b.sub"].is_binary
    refute by_name["submodule/z.gen"].is_binary
    assert Enum.join(by_name["submodule/z.gen"].hunks) =~ "-old\n+new"

    assert {:ok, files} = Git.range_file_diffs(dir, "main", "submodule", :two_dot)
    by_name = Map.new(files, &{&1.file_name, &1})
    assert by_name["submodule/a.sub"].is_binary
    refute by_name["submodule/z.gen"].is_binary
  end

  test "the staged text patch names only the -diff text files", %{staged: staged} do
    stub_git("--text", fn argv ->
      send(self(), {:ran, argv})
      :real
    end)

    by_name = staged_by_name(staged)
    refute by_name["patch/a.gen"].is_binary
    assert by_name["patch/logo.bin"].is_binary
    assert [_ | _] = ran = collect_ran([])
    assert Enum.any?(ran, &("patch/a.gen" in &1))
    refute Enum.any?(ran, &("patch/logo.bin" in &1))
  end

  test "a failed staged text patch shows on each -diff text file", %{staged: staged} do
    stub_git("--text", {"text-diff-failed", 1})

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      by_name = staged_by_name(staged)
      a = by_name["patch/a.gen"]
      refute a.is_binary
      assert a.hunks == []
      assert Enum.join(a.read_errors) =~ "text-diff-failed"
      assert by_name["patch/plain.txt"].read_errors == []
    end)
  end

  test "a review with no -diff file reads no blob and runs no text diff", %{unborn: unborn} do
    stub_git(fn argv ->
      send(self(), {:ran, argv})
      :real
    end)

    assert {:ok, [binary, _text]} = staged_in(unborn, "plain")
    assert binary.is_binary
    ran = collect_ran([])
    refute Enum.any?(ran, &match?(["sh" | _], &1))
    refute Enum.any?(ran, &("--text" in &1))
  end

  test "a path check-attr leaves out gets an error, not an answer", %{unborn: unborn} do
    stub_git("check-attr", {"", 0})

    assert Git.linguist_generated_many(unborn, ["a.txt"]) == %{
             "a.txt" => {:error, "`git check-attr` returned no row for a.txt"}
           }
  end

  test "a review with no binary file looks up no diff attribute", %{unborn: unborn} do
    stub_git("check-attr", fn argv ->
      send(self(), {:ran, argv})
      :real
    end)

    assert {:ok, [_file]} = staged_in(unborn, "text")
    refute Enum.any?(collect_ran([]), &("diff" in &1))
  end

  test "a renamed -diff text file shows its lines and an attribute lookup failure keeps it binary",
       %{staged: staged, by_name: by_name} do
    file = by_name["rename/new.gen"]
    assert file.status == :renamed
    refute file.is_binary
    assert Enum.join(file.hunks) =~ "+extra"
    assert {file.additions, file.deletions} == {1, 0}

    stub_git("binary", {"check-attr failed", 1})

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert_binary(staged_by_name(staged)["rename/new.gen"], :renamed)
    end)
  end

  test "a range review shows a -diff text file's lines and keeps real binaries binary", %{
    staged: range
  } do
    assert git(range, ["diff", "--numstat", "base", "tip"]) =~ "-\t-\tgen/a.gen"
    assert {:ok, files} = Git.range_file_diffs(range, "base", "tip", :two_dot)
    by_name = Map.new(files, &{&1.file_name, &1})
    a = by_name["gen/a.gen"]
    refute a.is_binary
    assert Enum.join(a.hunks) =~ "-one\n+two"
    assert {a.additions, a.deletions} == {1, 1}
    assert a.read_errors == []
    nul = by_name["gen/nul.gen"]
    assert nul.is_binary
    assert nul.hunks == []
    renamed = by_name["gen/renamed.gen"]
    refute renamed.is_binary
    assert renamed.status == :renamed
    assert Enum.join(renamed.hunks) =~ "+extra"
  end

  test "a three-dot review judges a -diff file by the merge base, not the base's tip", %{
    staged: range
  } do
    assert git(range, ["diff", "--numstat", "main-moved...topic"]) =~ "-\t-\tfork.gen"
    assert {:ok, [fork]} = Git.range_file_diffs(range, "main-moved", "topic", :three_dot)
    refute fork.is_binary
    assert Enum.join(fork.hunks) =~ "-fork one\n+fork two"
  end

  test "actual binary bytes are removed before JSON encoding", %{
    staged: staged,
    by_name: by_name
  } do
    file = by_name["binary/new b/name with spaces.bin"]
    assert_binary(file, :renamed)
    assert file.effective_oid == git(staged, ["rev-parse", ":binary/new b/name with spaces.bin"])
    assert Jason.encode!(file) =~ "is_binary"
  end

  test "a binary deletion whose HEAD blob lookup fails carries an empty OID", %{staged: staged} do
    stub_git("ls-tree", {"", 1})

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      file = staged_by_name(staged)["binary/gone.blob"]
      assert file.is_binary
      assert file.effective_oid == ""
    end)
  end

  test "binary additions in an unborn repository are represented explicitly", %{unborn: unborn} do
    assert {:ok, [file, _text]} = staged_in(unborn, "plain")
    assert_binary(file, :added)
  end

  test "binary deletion and exact rename retain status and unambiguous paths", %{
    by_name: by_name
  } do
    assert_binary(by_name["binary/gone.blob"], :deleted)
    renamed = by_name["binary/new b/name with spaces.bin"]
    assert_binary(renamed, :renamed)
    assert renamed.old_file_name == "binary/old b/name with spaces.bin"
  end

  test "mixed text and binary additions, deletions, renames and generated files", %{
    by_name: by_name,
    staged_files: files,
    staged_stderr: stderr
  } do
    assert length(files) == map_size(by_name)

    assert by_name |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "mixed/")) |> Enum.sort() ==
             ~w(mixed/added.md mixed/generated.blob mixed/gone.blob mixed/new.blob mixed/query.clj)

    assert_binary(by_name["mixed/gone.blob"], :deleted)
    assert_binary(by_name["mixed/new.blob"], :renamed)
    assert by_name["mixed/new.blob"].old_file_name == "mixed/old.blob"
    assert_binary(by_name["mixed/added.md"], :added)
    assert_binary(by_name["mixed/generated.blob"], :added)
    assert by_name["mixed/generated.blob"].is_generated
    refute by_name["mixed/new.blob"].is_generated
    refute by_name["mixed/query.clj"].is_binary
    assert Enum.join(by_name["mixed/query.clj"].hunks) =~ "+(new-mixed-query)"
    refute stderr =~ "couldn't parse staged-diff block"
  end

  test "numstat failure keeps every file listed with the reason", %{staged: staged} do
    stub_git("--numstat", {"numstat-failed", 1})

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      file = staged_by_name(staged)["patch/logo.bin"]
      assert Enum.join(file.read_errors) =~ "couldn't identify binary files"
      assert Enum.join(file.read_errors) =~ "exited 1"
    end)
  end

  test "numstat output truncated mid-entry degrades to a listed read error", %{staged: staged} do
    # A rename entry cut off before the trailing NUL makes the parser run
    # off the end of the entry list instead of seeing the empty tail.
    stub_git("--numstat", {"1\t2\t\0old.bin\0new.bin", 0})

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        file = staged_by_name(staged)["bazel/query.clj"]
        assert Enum.join(file.read_errors) =~ "couldn't parse binary file statistics"
      end)

    assert stderr =~ "couldn't parse binary file statistics"
  end

  test "a stability re-check that fails reports the git error instead of crashing", %{
    unborn: unborn
  } do
    # Both index probes run `ls-files --stage`; fail only the second.
    probes = :counters.new(1, [])

    stub_git("--stage", fn _argv ->
      :counters.add(probes, 1, 1)
      if :counters.get(probes, 1) >= 2, do: {"stage-probe-failed", 1}, else: :real
    end)

    assert {:error, reason} = staged_in(unborn, "text")
    assert reason =~ "ls-files"
  end

  test "patch parse failure survives whitespace filtering as visible read errors", %{
    unborn: unborn
  } do
    stub_git("-U3", {"diff --git malformed\n@@ -1 +1 @@\n-x\n+y\n", 0})

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert {:ok, [file]} = staged_in(unborn, "text")
      assert file.file_name == "a.txt"
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

  test "binary blobs are not read for the notice", %{unborn: unborn} do
    stub_git("show", {"unexpected-blob-read", 1})
    {result, _stderr} = ExUnit.CaptureIO.with_io(:stderr, fn -> staged_in(unborn, "plain") end)
    assert {:ok, [file, _text]} = result
    assert_binary(file, :added)
  end

  test "a range review marks binary files, renames included, without reading their blobs", %{
    staged: range
  } do
    stub_git("show", {"unexpected-blob-read", 1})

    {result, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Git.range_file_diffs(range, "base", "tip", :two_dot)
      end)

    assert {:ok, files} = result
    by_name = Map.new(files, &{&1.file_name, &1})
    assert_binary(by_name["bin/logo.png"], :modified)
    assert_binary(by_name["bin/new.bin"], :added)
    assert_binary(by_name["bin/renamed.bin"], :renamed)
    assert by_name["bin/renamed.bin"].old_file_name == "bin/moved.bin"
    # The text file's reads hit the stub, so a binary read would too.
    refute by_name["bin/text.txt"].is_binary
    assert by_name["bin/text.txt"].read_errors != []
  end

  test "a range review keeps every file listed with the reason when numstat fails", %{
    staged: range
  } do
    stub_git("--numstat", {"", 1})

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert {:ok, files} = Git.range_file_diffs(range, "base", "tip", :two_dot)
      file = Enum.find(files, &(&1.file_name == "bin/text.txt"))
      refute file.is_binary
      assert file.hunks != []
      assert Enum.join(file.read_errors) =~ "couldn't identify binary files"
    end)
  end

  # Git's stderr on a successful numstat reaches no parser only because
  # meerkat keeps it out of the answer, so this needs a real process.
  test "successful numstat warnings do not corrupt structured output", %{unborn: unborn} do
    bin_dir = Meerkat.TestHelpers.tmp_path("meerkat-binary-bin")
    on_exit(fn -> File.rm_rf!(bin_dir) end)
    intercept_git(bin_dir, "--numstat", "echo rename-warning >&2")
    assert {:ok, [file, _text]} = staged_in(unborn, "plain")
    assert_binary(file, :added)
  end

  test "index changes during loading require a reload", %{unborn: unborn} do
    probes = :counters.new(1, [])

    # The second probe finds another file staged.
    stub_git("--stage", fn _argv ->
      :counters.add(probes, 1, 1)

      if :counters.get(probes, 1) >= 2,
        do: {"100644 #{String.duplicate("0", 40)} 0\tb.txt\0", 0},
        else: :real
    end)

    assert {:error, reason} = staged_in(unborn, "text")
    assert reason =~ "staged files changed while loading"
  end

  defp staged_by_name(staged) do
    assert {:ok, files} = Git.staged_file_diffs(staged)
    Map.new(files, &{&1.file_name, &1})
  end

  defp collect_ran(acc) do
    receive do
      {:ran, argv} -> collect_ran([argv | acc])
    after
      0 -> acc
    end
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
