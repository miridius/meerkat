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
  def detect(files) when is_list(files) do
    removed = collect_lines(files, ?-)
    added = collect_lines(files, ?+)

    files = Enum.map(files, &Map.put(&1, :moved_lines, []))

    cond do
      removed == [] -> files
      added == [] -> files
      true -> place_moves(files, removed, added)
    end
  end

  ## Internals

  defp place_moves(files, removed, added) do
    removed_arr = List.to_tuple(removed)
    added_arr = List.to_tuple(added)
    added_index = build_index(added)

    candidates =
      removed
      |> Enum.with_index()
      |> Enum.flat_map(fn {%{content: c}, r_start} ->
        case Map.get(added_index, c) do
          nil ->
            []

          positions ->
            for a_start <- positions,
                len = run_length(removed_arr, r_start, added_arr, a_start),
                len >= @min_block_size,
                do: {r_start, a_start, len}
        end
      end)
      |> Enum.sort_by(fn {_r, _a, len} -> -len end)

    {moves, _, _} =
      Enum.reduce(candidates, {[], MapSet.new(), MapSet.new()}, fn {r_start, a_start, len},
                                                                   {acc, r_taken, a_taken} ->
        if range_overlaps?(r_start, len, r_taken) or range_overlaps?(a_start, len, a_taken) do
          {acc, r_taken, a_taken}
        else
          {[{r_start, a_start, len} | acc], mark_taken(r_taken, r_start, len),
           mark_taken(a_taken, a_start, len)}
        end
      end)

    # Build moved-line entries indexed by file_idx in O(M) total, then
    # do one pass over `files` to merge them in. The previous shape
    # was Enum.at + List.update_at per move (O(F + K) per move, with
    # `list ++ [block]` appends inside) — quadratic on large refactors.
    moved_by_file =
      moves
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {{r_start, a_start, len}, pair_id}, acc ->
        record_pair(acc, removed_arr, r_start, added_arr, a_start, len, pair_id, files)
      end)

    Enum.map(files, fn file ->
      Map.update(file, :moved_lines, [], fn existing ->
        existing ++ Enum.reverse(Map.get(moved_by_file, file.file_name, []))
      end)
    end)
  end

  defp range_overlaps?(_start, len, _taken) when len <= 0, do: false

  defp range_overlaps?(start, 1, taken), do: MapSet.member?(taken, start)

  defp range_overlaps?(start, len, taken) do
    # Fast-reject: a typical block of length L either entirely overlaps
    # an already-taken range (so the endpoints hit) or is entirely
    # disjoint. Probe the endpoints first to short-circuit the common
    # "no overlap" case in O(1) instead of O(L). Only fall through to
    # the full scan when an endpoint check is inconclusive.
    last = start + len - 1

    if MapSet.member?(taken, start) or MapSet.member?(taken, last) do
      true
    else
      Enum.any?(start..last, &MapSet.member?(taken, &1))
    end
  end

  defp mark_taken(taken, start, len) do
    Enum.reduce(start..(start + len - 1), taken, &MapSet.put(&2, &1))
  end

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

  # Extend candidate run as far as both content matches AND line
  # numbers continue to advance contiguously in the same file. A
  # break in file_idx or line continuity ends the run.
  defp run_length(removed_arr, r_start, added_arr, a_start) do
    do_run_length(removed_arr, r_start, added_arr, a_start, 0)
  end

  defp do_run_length(removed_arr, r_start, added_arr, a_start, k) do
    if r_start + k >= tuple_size(removed_arr) or a_start + k >= tuple_size(added_arr) do
      k
    else
      r = elem(removed_arr, r_start + k)
      a = elem(added_arr, a_start + k)

      cond do
        r.content != a.content ->
          k

        k > 0 and
            (r.file_idx != elem(removed_arr, r_start + k - 1).file_idx or
               a.file_idx != elem(added_arr, a_start + k - 1).file_idx or
               r.number != elem(removed_arr, r_start + k - 1).number + 1 or
               a.number != elem(added_arr, a_start + k - 1).number + 1) ->
          k

        true ->
          do_run_length(removed_arr, r_start, added_arr, a_start, k + 1)
      end
    end
  end

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
      Enum.flat_map(file.hunks || [], &collect_from_hunk(&1, file_idx, side_char))
    end)
  end

  defp collect_from_hunk(hunk, file_idx, side_char) do
    {_old, _new, acc} =
      hunk
      |> String.split("\n")
      |> Enum.reduce({0, 0, []}, fn line, {old_ln, new_ln, acc} ->
        cond do
          line == "" ->
            {old_ln, new_ln, acc}

          String.starts_with?(line, "@@ ") ->
            case parse_hunk_header(line) do
              {o, n} -> {o, n, acc}
              _ -> {old_ln, new_ln, acc}
            end

          true ->
            consume_line(line, old_ln, new_ln, acc, file_idx, side_char)
        end
      end)

    Enum.reverse(acc)
  end

  defp consume_line("-" <> rest, old_ln, new_ln, acc, file_idx, side_char) do
    acc =
      if side_char == ?- do
        maybe_add(acc, rest, file_idx, old_ln)
      else
        acc
      end

    {old_ln + 1, new_ln, acc}
  end

  defp consume_line("+" <> rest, old_ln, new_ln, acc, file_idx, side_char) do
    acc =
      if side_char == ?+ do
        maybe_add(acc, rest, file_idx, new_ln)
      else
        acc
      end

    {old_ln, new_ln + 1, acc}
  end

  defp consume_line(" " <> _rest, old_ln, new_ln, acc, _file_idx, _side_char) do
    {old_ln + 1, new_ln + 1, acc}
  end

  # No-newline-at-eof marker (`\`) or anything else: skip.
  defp consume_line(_other, old_ln, new_ln, acc, _file_idx, _side_char) do
    {old_ln, new_ln, acc}
  end

  defp maybe_add(acc, raw, file_idx, number) do
    content = String.trim(raw)

    if String.length(content) >= @min_line_chars do
      [%{file_idx: file_idx, number: number, content: content} | acc]
    else
      acc
    end
  end

  # Parse `@@ -10,5 +12,7 @@` → `{10, 12}`. Counts after the comma
  # are ignored (the hunk body tells the real story).
  defp parse_hunk_header(line) do
    case Regex.run(~r/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, line) do
      [_, old, new] -> {String.to_integer(old), String.to_integer(new)}
      _ -> nil
    end
  end
end
