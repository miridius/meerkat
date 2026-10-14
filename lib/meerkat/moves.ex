defmodule Meerkat.Moves do
  @moduledoc """
  Detect moved blocks of lines across the file list of a review.

  Scans every removed (`-`) and added (`+`) line across all files,
  pairs up maximal identical contiguous runs of `@min_block_size` or
  more, and attaches the resulting `moved_block` entries to each
  file's `:moved_lines` key. Same algorithm git uses for
  `--color-moved` (and GitHub's "Moved lines" indicator): exact-line
  matching with a minimum block size to suppress spurious matches on
  `}` / blanks. Cross-file AND within-file moves both detected.

  Greedy: the longest candidate runs win, shorter overlapping
  matches get suppressed.
  """

  @min_block_size 3
  # Trivial-line threshold — single tokens / single chars are
  # statistically noisy; we'd otherwise match every `}` across the
  # diff.
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
        r_span = span(r_start, len)
        a_span = span(a_start, len)

        if taken?(r_taken, r_span) or taken?(a_taken, a_span) do
          {acc, r_taken, a_taken}
        else
          {[{r_start, a_start, len} | acc], Enum.into(r_span, r_taken),
           Enum.into(a_span, a_taken)}
        end
      end)

    # Build moved-line entries indexed by file_idx in O(M) total, then
    # do one pass over `files` to merge them in.
    moved_by_file =
      moves
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {{r_start, a_start, len}, pair_id}, acc ->
        record_pair(acc, removed_arr, r_start, added_arr, a_start, len, pair_id, files)
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
            len >= @min_block_size,
            do: {r_start, a_start, len}
    end
  end

  # The positions a run of `len` lines from `start` covers.
  defp span(start, len), do: start..(start + len - 1)//1

  defp taken?(taken, span), do: Enum.any?(span, &MapSet.member?(taken, &1))

  defp record_pair(acc, removed_arr, r_start, added_arr, a_start, len, pair_id, files) do
    r_first = elem(removed_arr, r_start)
    r_last = elem(removed_arr, r_start + len - 1)
    a_first = elem(added_arr, a_start)
    a_last = elem(added_arr, a_start + len - 1)

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

  defp build_index(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {%{content: c}, pos}, acc ->
      Map.update(acc, c, [pos], &[pos | &1])
    end)
    |> Map.new(fn {k, vs} -> {k, Enum.reverse(vs)} end)
  end

  # Walk each file's hunks and emit one Line per `-` / `+` line on
  # the requested side. Strips whitespace, skips lines under
  # @min_line_chars chars (single-token noise).
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

  defp consume_line({:del, "-" <> rest}, {old_ln, new_ln, acc}, file_idx, side_char) do
    acc =
      if side_char == ?- do
        maybe_add(acc, rest, file_idx, old_ln)
      else
        acc
      end

    {old_ln + 1, new_ln, acc}
  end

  defp consume_line({:add, "+" <> rest}, {old_ln, new_ln, acc}, file_idx, side_char) do
    acc =
      if side_char == ?+ do
        maybe_add(acc, rest, file_idx, new_ln)
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

  defp maybe_add(acc, raw, file_idx, number) do
    content = String.trim(raw)

    if String.length(content) >= @min_line_chars do
      [%{file_idx: file_idx, number: number, content: content} | acc]
    else
      acc
    end
  end

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

  @doc false
  # The lines of a hunk body, each as `{kind, line}` with `kind` one of
  # `:context`, `:del`, `:add` or `:other` (a `\ No newline` marker).
  # Like `@git-diff-view`, an empty line is context: git writes a blank
  # context line that way under `diff.suppressBlankEmpty`. Only the
  # empty string after the body's final newline is no line.
  # `Meerkat.Intraline` shares it.
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
end
