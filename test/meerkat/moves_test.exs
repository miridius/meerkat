defmodule Meerkat.MovesTest do
  use ExUnit.Case, async: true

  alias Meerkat.Moves

  defp file(name, hunks) do
    %{
      file_name: name,
      old_file_name: nil,
      old_content: "",
      new_content: "",
      hunks: hunks,
      status: :modified,
      read_errors: [],
      effective_oid: "",
      moved_lines: []
    }
  end

  defp hunk(old_start, new_start, lines) do
    {old_count, new_count} =
      Enum.reduce(lines, {0, 0}, fn
        {"-", _}, {o, n} -> {o + 1, n}
        {"+", _}, {o, n} -> {o, n + 1}
        {" ", _}, {o, n} -> {o + 1, n + 1}
      end)

    header = "@@ -#{old_start},#{old_count} +#{new_start},#{new_count} @@\n"
    body = Enum.map_join(lines, "\n", fn {m, c} -> "#{m}#{c}" end)
    header <> body <> "\n"
  end

  defp lines(marker, contents), do: Enum.map(contents, &{marker, &1})

  defp block(side, first..last//1, pair_id, to_file, to_first..to_last//1) do
    %{
      side: side,
      line_start: first,
      line_end: last,
      pair_id: pair_id,
      to_file: to_file,
      to_side: if(side == :old, do: :new, else: :old),
      to_line_start: to_first,
      to_line_end: to_last
    }
  end

  defp moved(files), do: files |> Moves.detect() |> Enum.map(& &1.moved_lines)

  @abc ["alpha line one", "beta line two", "gamma line three"]

  describe "detect/1" do
    test "matches a cross-file move, numbering each side past context" do
      files = [
        file("a.txt", [hunk(5, 7, [{" ", "stable"} | lines("-", @abc)])]),
        file("b.txt", [hunk(3, 1, [{" ", "stable"} | lines("+", @abc)])])
      ]

      assert moved(files) == [
               [block(:old, 6..8, 0, "b.txt", 2..4)],
               [block(:new, 2..4, 0, "a.txt", 6..8)]
             ]
    end

    test "ignores runs under min block size" do
      files = [
        file("a.txt", [hunk(1, 1, lines("-", ["alpha line one", "beta line two"]))]),
        file("b.txt", [hunk(1, 1, lines("+", ["alpha line one", "beta line two"]))])
      ]

      assert moved(files) == [[], []]
    end

    test "lines of 3 characters count, shorter ones do not" do
      for {words, expected} <- [
            {["abc", "abd", "abe"],
             [[block(:old, 1..3, 0, "b.txt", 1..3)], [block(:new, 1..3, 0, "a.txt", 1..3)]]},
            {["ab", "ac", "ad"], [[], []]}
          ] do
        files = [
          file("a.txt", [hunk(1, 1, lines("-", words))]),
          file("b.txt", [hunk(1, 1, lines("+", words))])
        ]

        assert moved(files) == expected
      end
    end

    test "intra-file move within the same file" do
      files = [
        file("a.txt", [
          hunk(1, 1, lines("-", @abc) ++ [{" ", "stable"}] ++ lines("+", @abc))
        ])
      ]

      assert moved(files) == [
               [block(:old, 1..3, 0, "a.txt", 2..4), block(:new, 2..4, 0, "a.txt", 1..3)]
             ]
    end

    test "greedy: the longest match wins over an earlier, shorter one" do
      files = [
        file("short.txt", [hunk(1, 1, lines("-", @abc))]),
        file("long.txt", [hunk(1, 1, lines("-", @abc ++ ["delta line four"]))]),
        file("dst.txt", [hunk(1, 1, lines("+", @abc ++ ["delta line four"]))])
      ]

      assert moved(files) == [
               [],
               [block(:old, 1..4, 0, "dst.txt", 1..4)],
               [block(:new, 1..4, 0, "long.txt", 1..4)]
             ]
    end

    test "a shorter match sharing only its last line with a longer one is dropped" do
      cdef = ["gamma line three", "delta line four", "epsilon line five", "zeta line six"]

      files = [
        file("a.txt", [hunk(1, 1, lines("-", @abc ++ tl(cdef)))]),
        file("b.txt", [hunk(1, 1, lines("+", cdef))]),
        file("c.txt", [hunk(1, 1, lines("+", @abc))])
      ]

      assert moved(files) == [
               [block(:old, 3..6, 0, "b.txt", 1..4)],
               [block(:new, 1..4, 0, "a.txt", 3..6)],
               []
             ]
    end

    test "a block copied to two places moves to the first" do
      files = [
        file("a.txt", [hunk(1, 1, lines("-", @abc))]),
        file("b.txt", [hunk(1, 1, lines("+", @abc))]),
        file("c.txt", [hunk(1, 1, lines("+", @abc))])
      ]

      assert moved(files) == [
               [block(:old, 1..3, 0, "b.txt", 1..3)],
               [block(:new, 1..3, 0, "a.txt", 1..3)],
               []
             ]
    end

    test "adjacent blocks move to different places" do
      def_ = ["delta line four", "epsilon line five", "zeta line six"]

      files = [
        file("a.txt", [hunk(1, 1, lines("-", @abc ++ def_))]),
        file("b.txt", [hunk(1, 1, lines("+", @abc))]),
        file("c.txt", [hunk(1, 1, lines("+", def_))])
      ]

      assert moved(files) == [
               [block(:old, 1..3, 0, "b.txt", 1..3), block(:old, 4..6, 1, "c.txt", 1..3)],
               [block(:new, 1..3, 0, "a.txt", 1..3)],
               [block(:new, 1..3, 1, "a.txt", 4..6)]
             ]
    end

    test "a run stops at the end of either side's lines" do
      longer = @abc ++ ["delta line four"]

      for {old, new} <- [{@abc, longer}, {longer, @abc}] do
        files = [
          file("a.txt", [hunk(1, 1, lines("-", old))]),
          file("b.txt", [hunk(1, 1, lines("+", new))])
        ]

        assert moved(files) == [
                 [block(:old, 1..3, 0, "b.txt", 1..3)],
                 [block(:new, 1..3, 0, "a.txt", 1..3)]
               ]
      end
    end

    test "a gap in line numbers or a change of file on either side ends a run" do
      gap = [
        hunk(1, 1, lines("-", Enum.take(@abc, 1))),
        hunk(5, 5, lines("-", Enum.drop(@abc, 1)))
      ]

      contiguous = [hunk(1, 1, lines("-", @abc))]
      added = &[hunk(1, 1, lines("+", &1))]

      cases = [
        # removed side has a gap
        [file("a.txt", gap), file("b.txt", added.(@abc))],
        # removed side changes file, though the numbers run on
        [
          file("a.txt", [hunk(1, 1, lines("-", Enum.take(@abc, 2)))]),
          file("b.txt", [hunk(3, 3, lines("-", Enum.drop(@abc, 2)))]),
          file("c.txt", added.(@abc))
        ],
        # added side has a gap
        [
          file("a.txt", contiguous),
          file("b.txt", [
            hunk(1, 1, lines("+", Enum.take(@abc, 1))),
            hunk(5, 5, lines("+", Enum.drop(@abc, 1)))
          ])
        ],
        # added side changes file, though the numbers run on
        [
          file("a.txt", contiguous),
          file("b.txt", [hunk(1, 1, lines("+", Enum.take(@abc, 2)))]),
          file("c.txt", [hunk(3, 3, lines("+", Enum.drop(@abc, 2)))])
        ]
      ]

      for files <- cases do
        assert Enum.all?(moved(files), &(&1 == [])), inspect(files)
      end
    end

    test "added lines are not matched against themselves" do
      files = [
        file("a.txt", [hunk(1, 1, lines("-", ["unrelated removed line"]))]),
        file("b.txt", [hunk(1, 1, lines("+", @abc))])
      ]

      assert moved(files) == [[], []]
    end

    test "removed lines are not matched against themselves" do
      files = [
        file("a.txt", [hunk(1, 1, lines("-", @abc))]),
        file("b.txt", [hunk(1, 1, lines("+", ["unrelated added line"]))])
      ]

      assert moved(files) == [[], []]
    end

    test "a no-newline marker does not advance line numbers" do
      a =
        "@@ -1,1 +1,4 @@\n-old last line\n\\ No newline at end of file\n" <>
          Enum.map_join(@abc, &"+#{&1}\n")

      files = [
        file("a.txt", [a]),
        file("b.txt", [hunk(1, 1, lines("-", @abc))])
      ]

      assert moved(files) == [
               [block(:new, 1..3, 0, "b.txt", 1..3)],
               [block(:old, 1..3, 0, "a.txt", 1..3)]
             ]
    end

    # Git writes a blank context line as an empty line under
    # `diff.suppressBlankEmpty`; `@git-diff-view` numbers it as context.
    test "an empty line counts as a context line" do
      a = "@@ -1,4 +1,1 @@\n\n" <> Enum.map_join(@abc, &"-#{&1}\n")

      files = [
        file("a.txt", [a]),
        file("b.txt", [hunk(1, 1, lines("+", @abc))])
      ]

      assert moved(files) == [
               [block(:old, 2..4, 0, "b.txt", 1..3)],
               [block(:new, 1..3, 0, "a.txt", 2..4)]
             ]
    end

    test "a hunk with an unreadable header contributes no lines" do
      files = [
        file("a.txt", ["not a header\n" <> Enum.map_join(@abc, &"-#{&1}\n")]),
        file("b.txt", [hunk(1, 1, lines("+", @abc))])
      ]

      assert moved(files) == [[], []]
    end

    test "stale moved_lines are overwritten" do
      files = [
        %{file("solo.txt", [hunk(1, 1, [{"-", "alpha"}, {"+", "beta"}])]) | moved_lines: [:stale]}
      ]

      assert moved(files) == [[]]
    end
  end
end
