defmodule Meerkat.Moves do
  @moduledoc """
  Detect moved blocks of lines across the file list of a review.

  Scans every removed (`-`) and added (`+`) line across all files and
  attaches the moved blocks it finds to each file's `:moved_lines`
  key. Lines are compared with surrounding whitespace trimmed. A
  line of `@min_line_chars` or more characters is substantial; a
  shorter one, such as a blank or `}`, is short.

  - A block is a run of identical consecutive removed and added lines
    that starts at a substantial line. Short lines inside it must
    match too, and do not break it.
  - It needs `@min_substantial_lines` substantial lines.
  - On each side, the changed short lines directly before and after
    it join the block, unless a longer block has taken them. git often puts a moved block's blank line
    after it on one side and before it on the other.
  - It counts as moved when it has `@min_block_size` lines on either
    side, and the block covers those lines on each side.

  Cross-file and within-file moves are both found. Greedy: the
  longest runs win, and shorter overlapping ones are dropped.
  """

  @min_block_size 3
  @min_substantial_lines 2
  @min_line_chars 3

  @type side :: :old | :new
  @type moved_block :: %{
          side: side,
          line_start: pos_integer(),
          line_end: pos_integer(),
          pair_id: non_neg_integer(),
          to_file: String.t(),
          to_side: side,
          to_line_start: pos_integer(),
          to_line_end: pos_integer()
        }

  @doc """
  Annotate `files` with `:moved_lines`. Idempotent: callers may pass
  files that already have a `:moved_lines` key (it will be
  overwritten).
  """
  @spec detect([map()]) :: [map()]
  def detect(files) do
    removed = collect_lines(files, ?-)
    added = collect_lines(files, ?+)
    removed_arr = List.to_tuple(removed)
    added_arr = List.to_tuple(added)
    added_index = build_index(added)

    candidates =
      removed
      |> Enum.with_index()
      |> Enum.flat_map(&candidates_from(&1, added_index, removed_arr, added_arr))
      |> Enum.sort_by(&elem(&1, 2), :desc)

    {moves, _, _} =
      Enum.reduce(candidates, {[], MapSet.new(), MapSet.new()}, fn {r_start, a_start, len},
                                                                   {acc, r_taken, a_taken} ->
        r = extend(removed_arr, r_start, len, r_taken)
        a = extend(added_arr, a_start, len, a_taken)

        if taken?(r_taken, r) or taken?(a_taken, a) or not qualifies?(removed_arr, r, a) do
          {acc, r_taken, a_taken}
        else
          {[{r, a} | acc], Enum.into(r, r_taken), Enum.into(a, a_taken)}
        end
      end)

    # Build moved-line entries indexed by file_idx in O(M) total, then
    # do one pass over `files` to merge them in.
    moved_by_file =
      moves
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {{r, a}, pair_id}, acc ->
        record_pair(acc, removed_arr, r, added_arr, a, pair_id, files)
      end)

    Enum.map(files, fn file ->
      Map.put(file, :moved_lines, Enum.reverse(Map.get(moved_by_file, file.file_name, [])))
    end)
  end

  ## Internals

  defp candidates_from({%{content: c}, r_start}, added_index, removed_arr, added_arr) do
    case Map.get(added_index, c) do
      nil ->
        []

      positions ->
        for a_start <- positions,
            len = run_length(removed_arr, r_start, added_arr, a_start),
            len >= @min_substantial_lines,
            do: {r_start, a_start, len}
    end
  end

  # The block's index range on one side: the run, widened over the
  # changed short lines directly before and after it that no block
  # has taken yet.
  defp extend(arr, start, len, taken) do
    widen_back(arr, start, taken)..widen_forward(arr, start + len - 1, taken)
  end

  defp widen_back(arr, i, taken) do
    if i > 0 and joins?(arr, i - 1, taken) and continues?(elem(arr, i - 1), elem(arr, i)),
      do: widen_back(arr, i - 1, taken),
      else: i
  end

  defp widen_forward(arr, i, taken) do
    if i + 1 < tuple_size(arr) and joins?(arr, i + 1, taken) and
         continues?(elem(arr, i), elem(arr, i + 1)),
       do: widen_forward(arr, i + 1, taken),
       else: i
  end

  defp joins?(arr, j, taken), do: not substantial?(elem(arr, j)) and not MapSet.member?(taken, j)

  # The widened lines are all short, so counting over the whole block
  # counts the run's substantial lines.
  defp qualifies?(removed_arr, r, a) do
    Enum.count(r, &substantial?(elem(removed_arr, &1))) >= @min_substantial_lines and
      (Range.size(r) >= @min_block_size or Range.size(a) >= @min_block_size)
  end

  defp substantial?(line), do: String.length(line.content) >= @min_line_chars

  defp taken?(taken, range), do: Enum.any?(range, &MapSet.member?(taken, &1))

  defp record_pair(acc, removed_arr, r, added_arr, a, pair_id, files) do
    r_first = elem(removed_arr, r.first)
    r_last = elem(removed_arr, r.last)
    a_first = elem(added_arr, a.first)
    a_last = elem(added_arr, a.last)

    # Look up file names by file_idx via Enum.at — these are stable
    # post-mount and called at most twice per move. The O(idx) cost
    # here is bounded by the move count, not multiplied by it.
    r_name = Enum.at(files, r_first.file_idx).file_name
    a_name = Enum.at(files, a_first.file_idx).file_name

    old_block = %{
      side: :old,
      line_start: r_first.number,
      line_end: r_last.number,
      pair_id: pair_id,
      to_file: a_name,
      to_side: :new,
      to_line_start: a_first.number,
      to_line_end: a_last.number
    }

    new_block = %{
      side: :new,
      line_start: a_first.number,
      line_end: a_last.number,
      pair_id: pair_id,
      to_file: r_name,
      to_side: :old,
      to_line_start: r_first.number,
      to_line_end: r_last.number
    }

    acc
    |> Map.update(r_name, [old_block], &[old_block | &1])
    |> Map.update(a_name, [new_block], &[new_block | &1])
  end

  # The length of the run starting at the matching lines `r` and `a`.
  # The run extends while the next lines on both sides match AND
  # continue contiguously in the same file.
  defp run_length(removed_arr, r, added_arr, a, len \\ 1) do
    if r + 1 < tuple_size(removed_arr) and a + 1 < tuple_size(added_arr) and
         extends?(removed_arr, r, added_arr, a) do
      run_length(removed_arr, r + 1, added_arr, a + 1, len + 1)
    else
      len
    end
  end

  defp extends?(removed_arr, r, added_arr, a) do
    next_r = elem(removed_arr, r + 1)
    next_a = elem(added_arr, a + 1)

    next_r.content == next_a.content and continues?(elem(removed_arr, r), next_r) and
      continues?(elem(added_arr, a), next_a)
  end

  defp continues?(prev, line),
    do: line.file_idx == prev.file_idx and line.number == prev.number + 1

  # Indexes substantial lines only, as only they start a block.
  defp build_index(lines) do
    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _pos} -> substantial?(line) end)
    |> Enum.reduce(%{}, fn {%{content: c}, pos}, acc ->
      Map.update(acc, c, [pos], &[pos | &1])
    end)
    |> Map.new(fn {k, vs} -> {k, Enum.reverse(vs)} end)
  end

  # Walk each file's hunks and emit one Line per `-` / `+` line on
  # the requested side, with surrounding whitespace stripped.
  defp collect_lines(files, side_char) do
    files
    |> Enum.with_index()
    |> Enum.flat_map(fn {file, file_idx} ->
      Enum.flat_map(file.hunks, &collect_from_hunk(&1, file_idx, side_char))
    end)
  end

  defp collect_from_hunk(hunk, file_idx, side_char) do
    with [header, body] <- String.split(hunk, "\n", parts: 2),
         {old_ln, new_ln} <- parse_hunk_header(header) do
      body
      |> hunk_lines()
      |> Enum.reduce({old_ln, new_ln, []}, &consume_line(&1, &2, file_idx, side_char))
      |> elem(2)
      |> Enum.reverse()
    else
      _ -> []
    end
  end

  @doc false
  # The lines of a hunk body, each as `{kind, line}` with `kind` one of
  # `:context`, `:del`, `:add` or `:other` (any other line, such as a
  # `\ No newline` marker). Like `@git-diff-view`, an empty line is
  # context: git writes a blank context line that way under
  # `diff.suppressBlankEmpty`. Only the empty string after the body's
  # final newline is no line. `Meerkat.Intraline` shares it.
  def hunk_lines(body) do
    lines = String.split(body, "\n")
    lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
    Enum.map(lines, &{hunk_line_kind(&1), &1})
  end

  defp hunk_line_kind(""), do: :context
  defp hunk_line_kind(" " <> _), do: :context
  defp hunk_line_kind("-" <> _), do: :del
  defp hunk_line_kind("+" <> _), do: :add
  defp hunk_line_kind(_), do: :other

  defp consume_line({:del, "-" <> rest}, {old_ln, new_ln, acc}, file_idx, side_char) do
    acc =
      if side_char == ?- do
        add_line(acc, rest, file_idx, old_ln)
      else
        acc
      end

    {old_ln + 1, new_ln, acc}
  end

  defp consume_line({:add, "+" <> rest}, {old_ln, new_ln, acc}, file_idx, side_char) do
    acc =
      if side_char == ?+ do
        add_line(acc, rest, file_idx, new_ln)
      else
        acc
      end

    {old_ln, new_ln + 1, acc}
  end

  defp consume_line({:context, _}, {old_ln, new_ln, acc}, _file_idx, _side_char) do
    {old_ln + 1, new_ln + 1, acc}
  end

  # No-newline-at-eof marker (`\`) or anything else: skip.
  defp consume_line({:other, _}, state, _file_idx, _side_char), do: state

  defp add_line(acc, raw, file_idx, number),
    do: [%{file_idx: file_idx, number: number, content: String.trim(raw)} | acc]

  @doc false
  # Parse `@@ -10,5 +12,7 @@` → `{10, 12}`, or `nil` for any other
  # line. Counts after the comma are ignored (the hunk body tells the
  # real story). `Meerkat.Intraline` shares it.
  def parse_hunk_header(line) do
    case Regex.run(~r/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, line) do
      [_, old, new] -> {String.to_integer(old), String.to_integer(new)}
      _ -> nil
    end
  end
end
