defmodule Meerkat.MovesTest do
  use ExUnit.Case, async: true

  alias Meerkat.Moves

  defp file(name, hunks) do
    %{
      file_name: name,
      old_file_name: nil,
      language: "",
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

  describe "detect/1" do
    test "matches a cross-file move (min block size 3)" do
      files = [
        file("a.txt", [
          hunk(1, 1, [
            {"-", "alpha line one"},
            {"-", "beta line two"},
            {"-", "gamma line three"},
            {" ", "stable"}
          ])
        ]),
        file("b.txt", [
          hunk(1, 1, [
            {" ", "stable"},
            {"+", "alpha line one"},
            {"+", "beta line two"},
            {"+", "gamma line three"}
          ])
        ])
      ]

      [a, b] = Moves.detect(files)

      assert [%{side: :old, line_start: 1, line_end: 3, to_file: "b.txt"}] = a.moved_lines
      assert [%{side: :new, line_start: 2, line_end: 4, to_file: "a.txt"}] = b.moved_lines
      assert hd(a.moved_lines).pair_id == hd(b.moved_lines).pair_id
    end

    test "ignores runs under min block size" do
      files = [
        file("a.txt", [
          hunk(1, 1, [{"-", "alpha line one"}, {"-", "beta line two"}])
        ]),
        file("b.txt", [
          hunk(1, 1, [{"+", "alpha line one"}, {"+", "beta line two"}])
        ])
      ]

      [a, b] = Moves.detect(files)
      assert a.moved_lines == []
      assert b.moved_lines == []
    end

    test "drops trivial short lines (< 3 chars)" do
      files = [
        file("a.txt", [
          hunk(1, 1, [{"-", "}"}, {"-", "}"}, {"-", "}"}, {"-", "}"}])
        ]),
        file("b.txt", [
          hunk(1, 1, [{"+", "}"}, {"+", "}"}, {"+", "}"}, {"+", "}"}])
        ])
      ]

      [a, b] = Moves.detect(files)
      assert a.moved_lines == []
      assert b.moved_lines == []
    end

    test "intra-file move within the same file" do
      files = [
        file("a.txt", [
          hunk(1, 1, [
            {"-", "alpha line one"},
            {"-", "beta line two"},
            {"-", "gamma line three"},
            {" ", "stable"},
            {"+", "alpha line one"},
            {"+", "beta line two"},
            {"+", "gamma line three"}
          ])
        ])
      ]

      [a] = Moves.detect(files)

      assert length(a.moved_lines) == 2
      assert Enum.any?(a.moved_lines, &(&1.side == :old and &1.to_file == "a.txt"))
      assert Enum.any?(a.moved_lines, &(&1.side == :new and &1.to_file == "a.txt"))
    end

    test "greedy: longest match wins over shorter overlapping match" do
      # Two candidate runs share an added position; the 4-line match
      # should win and the 3-line one should be suppressed.
      files = [
        file("src.txt", [
          hunk(1, 1, [
            {"-", "alpha line one"},
            {"-", "beta line two"},
            {"-", "gamma line three"},
            {"-", "delta line four"}
          ])
        ]),
        file("dst.txt", [
          hunk(1, 1, [
            {"+", "alpha line one"},
            {"+", "beta line two"},
            {"+", "gamma line three"},
            {"+", "delta line four"}
          ])
        ])
      ]

      [_, dst] = Moves.detect(files)
      assert [%{line_start: 1, line_end: 4}] = dst.moved_lines
    end

    test "moved_lines always present (empty list when no moves)" do
      files = [file("solo.txt", [hunk(1, 1, [{"-", "alpha"}, {"+", "beta"}])])]
      [f] = Moves.detect(files)
      assert f.moved_lines == []
    end
  end
end
