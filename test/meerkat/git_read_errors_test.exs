defmodule Meerkat.GitReadErrorsTest do
  # Staged and range reviews against a git `stub_git` stands in for
  # entirely, so each lookup can fail on its own and every reason lands
  # where the reviewer reads it.
  use ExUnit.Case, async: true

  import Meerkat.TestHelpers, only: [stub_git: 1]

  alias Meerkat.Git

  @repo "repo"

  # Answers each command a review runs from `answers`, keyed by `kind/1`;
  # a kind `answers` leaves out gets `default/2`'s answer. An answer is
  # an `{output, status}` or a function of the argv returning one.
  defp fake_git(answers) do
    stub_git(fn argv ->
      kind = kind(argv)

      case Map.get(answers, kind, &default(kind, &1)) do
        answer when is_function(answer) -> answer.(argv)
        answer -> answer
      end
    end)
  end

  defp kind(["sh" | _]), do: :cat_file
  defp kind(["git", "ls-files", "--stage", "-z"]), do: :index
  defp kind(["git", "diff", "--cached", "--name-status" | _]), do: :name_status
  defp kind(["git", "diff", "--name-status" | _]), do: :name_status
  defp kind(["git", "check-attr", "-z", "linguist-generated" | _]), do: :generated
  defp kind(["git", "check-attr", "-z", "diff", "binary" | _]), do: :diff_attrs
  defp kind(["git", "--literal-pathspecs", "-c", _, "ls-files" | _]), do: :staged_oids
  defp kind(["git", "diff", "--cached", "--numstat" | _]), do: :numstat
  defp kind(["git", "diff", "--numstat" | _]), do: :numstat
  defp kind(["git", "merge-base" | _]), do: :merge_base
  defp kind(["git", "show", _spec]), do: :show
  defp kind(["git", "--literal-pathspecs", "diff" | _]), do: :patch

  defp kind(["git", "-c", "core.quotePath=false", "--literal-pathspecs", "diff" | args]),
    do: if("--text" in args, do: :text_patch, else: :patch)

  defp default(:index, _argv), do: {"index", 0}
  defp default(:generated, argv), do: {attr_rows(argv, ["linguist-generated"]), 0}
  defp default(:diff_attrs, argv), do: {attr_rows(argv, ["diff", "binary"]), 0}
  defp default(:show, ["git", "show", spec]), do: {"#{spec}\n", 0}
  defp default(_kind, _argv), do: {"", 0}

  # `check-attr -z` rows leaving each of `attrs` unspecified for every path.
  defp attr_rows(argv, attrs) do
    [_ | paths] = Enum.drop_while(argv, &(&1 != "--"))
    for path <- paths, attr <- attrs, into: "", do: "#{path}\0#{attr}\0unspecified\0"
  end

  # `check-attr -z` rows unsetting `diff` on every path.
  defp diff_unset(argv) do
    [_ | paths] = Enum.drop_while(argv, &(&1 != "--"))
    {for(path <- paths, into: "", do: "#{path}\0diff\0unset\0#{path}\0binary\0unspecified\0"), 0}
  end

  # `git cat-file --batch` answers giving each object a line of text.
  defp text_blobs(["sh", "-c", _script | objects]),
    do: {for(_ <- objects, into: "", do: "abc blob 5\ntext\n\n"), 0}

  defp staged_review do
    {result, stderr} = ExUnit.CaptureIO.with_io(:stderr, fn -> Git.staged_file_diffs(@repo) end)
    assert {:ok, files} = result
    {files, stderr}
  end

  defp warning(message), do: "meerkat: warning — #{message}\n"

  test "each lookup that fails for a staged -diff text file is listed on it, in the order " <>
         "its content is read" do
    fake_git(%{
      name_status: {"D\0del.gen\0A\0add.gen\0R100\0old.gen\0ren.gen\0M\0mod.gen\0", 0},
      generated: {"attrs-unavailable\n", 1},
      staged_oids: {"index-unavailable\n", 1},
      numstat: {"-\t-\tdel.gen\0-\t-\tadd.gen\0-\t-\t\0old.gen\0ren.gen\0-\t-\tmod.gen\0", 0},
      diff_attrs: &diff_unset/1,
      cat_file: &text_blobs/1,
      text_patch: {"text-patch-unavailable\n", 1},
      show: {"bad-object\n", 128}
    })

    {files, stderr} = staged_review()

    generated =
      "couldn't read `linguist-generated` attribute (git check-attr -z linguist-generated -- " <>
        "del.gen add.gen ren.gen mod.gen exited 1: attrs-unavailable). Check your " <>
        "`.gitattributes` syntax."

    oids =
      "couldn't compute batched staged-blob OIDs (git --literal-pathspecs -c " <>
        "core.quotePath=false ls-files -s -- add.gen ren.gen mod.gen exited 1: " <>
        "index-unavailable); approve guard may flag files as stale"

    text =
      "couldn't compute batched staged diff (git -c core.quotePath=false " <>
        "--literal-pathspecs diff --cached -U3 --diff-filter=u -w -M --no-textconv " <>
        "--no-ext-diff --text -- del.gen del.gen add.gen add.gen old.gen ren.gen mod.gen " <>
        "mod.gen exited 1: text-patch-unavailable); per-file content may render empty"

    at_head = &"couldn't read #{&1} at HEAD: git show HEAD:#{&1} exited 128: bad-object"
    staged = &"couldn't read staged content for #{&1}: git show :0:#{&1} exited 128: bad-object"
    gen = &"linguist-generated check failed for #{&1}: #{generated}"

    assert Enum.map(
             files,
             &{&1.file_name, &1.is_binary, &1.hunks, &1.effective_oid, &1.read_errors}
           ) ==
             [
               {"del.gen", false, [], "", [at_head.("del.gen"), text, gen.("del.gen"), oids]},
               {"add.gen", false, [], "", [staged.("add.gen"), text, gen.("add.gen"), oids]},
               {"ren.gen", false, [], "",
                [at_head.("old.gen"), staged.("ren.gen"), text, gen.("ren.gen"), oids]},
               {"mod.gen", false, [], "",
                [at_head.("mod.gen"), staged.("mod.gen"), text, gen.("mod.gen"), oids]}
             ]

    assert stderr ==
             "meerkat: WARNING — #{generated}\n" <>
               Enum.map_join(
                 [oids, text] ++
                   [at_head.("del.gen"), staged.("add.gen"), at_head.("old.gen")] ++
                   [staged.("ren.gen"), at_head.("mod.gen"), staged.("mod.gen")],
                 &warning/1
               )
  end

  test "batched failures are listed on every staged file, OIDs first, and a file the batched " <>
         "patch leaves out has no hunks" do
    fake_git(%{
      name_status: {"D\0gone.rs\0R100\0old.rs\0new.rs\0M\0mod.rs\0", 0},
      staged_oids: {"index-unavailable\n", 1},
      numstat: {"numstat-unavailable\n", 1}
    })

    {files, stderr} = staged_review()

    oids =
      "couldn't compute batched staged-blob OIDs (git --literal-pathspecs -c " <>
        "core.quotePath=false ls-files -s -- new.rs mod.rs exited 1: index-unavailable); " <>
        "approve guard may flag files as stale"

    numstat =
      "couldn't identify binary files: git diff --cached --numstat -z -w -M --no-textconv " <>
        "--no-ext-diff exited 1: numstat-unavailable"

    assert Enum.map(files, &{&1.file_name, &1.hunks, &1.effective_oid, &1.read_errors}) == [
             {"gone.rs", [], "", [oids, numstat]},
             {"new.rs", [], "", [oids, numstat]},
             {"mod.rs", [], "", [oids, numstat]}
           ]

    assert stderr == warning(oids) <> warning(numstat)
  end

  for {output, case} <- [
        {"1\t2\t\0old.bin", "a rename cut off before its new path"},
        {"garbage\0", "a line without its counts"}
      ] do
    test "numstat output holding #{case} is listed as a read error" do
      fake_git(%{name_status: {"M\0a.rs\0", 0}, numstat: {unquote(output), 0}})

      {[file], stderr} = staged_review()

      assert file.read_errors == ["couldn't parse binary file statistics"]
      assert stderr == warning("couldn't parse binary file statistics")
    end
  end

  test "a -diff text file shows the text patch's hunks over any the batched patch gives it" do
    block = &"diff --git a/a.gen b/a.gen\n--- a/a.gen\n+++ b/a.gen\n@@ -1 +1 @@\n-x\n+#{&1}\n"

    fake_git(%{
      name_status: {"M\0a.gen\0", 0},
      numstat: {"-\t-\ta.gen\0", 0},
      diff_attrs: &diff_unset/1,
      cat_file: &text_blobs/1,
      patch: {block.("batched"), 0},
      text_patch: {block.("text"), 0}
    })

    assert {[%{is_binary: false, hunks: [hunk]}], ""} = staged_review()
    assert hunk =~ "+text"
  end

  test "a binary file whose name holds a tab is still binary" do
    fake_git(%{name_status: {"A\0a\tb.bin\0", 0}, numstat: {"-\t-\ta\tb.bin\0", 0}})

    assert {[%{file_name: "a\tb.bin", is_binary: true, read_errors: []}], ""} = staged_review()
  end

  test "each lookup that fails for a range file is listed on it, in the order its content " <>
         "is read" do
    fake_git(%{
      name_status: {"M\0m.txt\0", 0},
      merge_base: {"no-merge-base\n", 1},
      generated: {"attrs-unavailable\n", 1},
      patch: {"patch-unavailable\n", 1},
      show: {"bad-object\n", 128}
    })

    {result, stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Git.range_file_diffs(@repo, "base", "tip", :three_dot)
      end)

    generated =
      "couldn't read `linguist-generated` attribute (git check-attr -z linguist-generated -- " <>
        "m.txt exited 1: attrs-unavailable). Check your `.gitattributes` syntax."

    at = &"couldn't read m.txt at #{&1}: git show #{&1}:m.txt exited 128: bad-object"

    patch =
      "couldn't compute diff (args: --literal-pathspecs diff -U3 base..tip -- m.txt): " <>
        "git --literal-pathspecs diff -U3 base..tip -- m.txt exited 1: patch-unavailable"

    assert {:ok, [file]} = result

    assert file.read_errors == [
             at.("base"),
             at.("tip"),
             patch,
             "linguist-generated check failed for m.txt: #{generated}"
           ]

    assert stderr ==
             warning(
               "couldn't resolve merge-base for base...tip: git merge-base base tip exited 1: " <>
                 "no-merge-base. Falling back to two-dot diff against base."
             ) <>
               "meerkat: WARNING — #{generated}\n" <>
               warning(at.("base")) <> warning(at.("tip")) <> warning(patch)
  end

  test "a range file git shows no patch for has no hunks and no error" do
    fake_git(%{name_status: {"M\0m.txt\0", 0}})

    assert {:ok, [%{hunks: [], read_errors: []}]} =
             Git.range_file_diffs(@repo, "base", "tip", :two_dot)
  end
end
