defmodule Meerkat.Intraline do
  @moduledoc """
  Hunk pair-alignment for intra-line highlighting.

  `@git-diff-view` only runs fast-diff between paired `-` / `+` lines
  when the two sides of a `-`/`+` run have *equal* counts. A run with,
  say, 5 deletions and 4 additions — common when a wrapped source line
  gets joined or split — gets rendered plain on every pair, even though
  the first N of each side are trivially pairable.

  `split/1` walks each hunk and, whenever it finds a run with both
  deletions and additions, in different counts, splits the hunk into:

    1. a **paired sub-hunk** containing the first `min(dels, adds)` of
       each. The library sees equal counts and runs intra-line diff on
       every pair.
    2. an **orphan sub-hunk** containing the remaining lines from the
       longer side. These still render plain — there is no paired
       counterpart to diff against.

  Context, already-matched runs and runs with only deletions or only
  additions stay in their hunk unsplit. Every hunk's header is rebuilt
  as `@@ -a,b +c,d @@`, with git's line ranges but without the text
  git puts after the second `@@`.
  """

  alias Meerkat.Moves

  @doc """
  Split each hunk text in the list. Returns a flat list of hunk
  strings, possibly longer than the input.
  """
  @spec split([String.t()]) :: [String.t()]
  def split(hunks), do: Enum.flat_map(hunks, &split_one/1)

  defp split_one(hunk) do
    with [header, body] <- String.split(hunk, "\n", parts: 2),
         {old_start, new_start} <- Moves.parse_hunk_header(header) do
      split_body(hunk, body, old_start, new_start)
    else
      _ -> [hunk]
    end
  end

  defp split_body(orig_hunk, body, old_start, new_start) do
    state = %{
      acc: [],
      current: [],
      old_cur: old_start,
      new_cur: new_start,
      cur_old_start: old_start,
      cur_new_start: new_start
    }

    final = walk(Moves.hunk_lines(body), state)

    out =
      case final.current do
        [] -> final.acc
        cur -> [emit(Enum.reverse(cur), final.cur_old_start, final.cur_new_start) | final.acc]
      end

    case out do
      [] -> [orig_hunk]
      _ -> Enum.reverse(out)
    end
  end

  defp walk([], state), do: state

  defp walk([{:context, line} | rest], state) do
    walk(rest, %{
      state
      | current: [{:context, line} | state.current],
        old_cur: state.old_cur + 1,
        new_cur: state.new_cur + 1
    })
  end

  defp walk([{:other, line} | rest], state) do
    walk(rest, %{state | current: [{:other, line} | state.current]})
  end

  # `dels` and `adds` hold one entry per line: the line, then any
  # no-newline marker that follows it, so a marker stays with its line.
  defp walk(lines, state) do
    {dels, adds, rest} = collect_run(lines, [], [])
    post_old = state.old_cur + length(dels)
    post_new = state.new_cur + length(adds)
    {paired_dels, orphan_dels} = Enum.split(dels, length(adds))
    {paired_adds, orphan_adds} = Enum.split(adds, length(dels))
    # muex:ignore equivalent: one of the two lists is always empty
    orphan = orphan_dels ++ orphan_adds

    # A one-sided run has nothing to pair, so it stays in its hunk.
    if dels == [] or adds == [] or orphan == [] do
      walk(rest, %{
        state
        | current: Enum.reverse(Enum.concat(dels ++ adds), state.current),
          old_cur: post_old,
          new_cur: post_new
      })
    else
      pair_count = length(paired_dels)
      paired = Enum.reverse(state.current, Enum.concat(paired_dels ++ paired_adds))

      acc = [
        emit(Enum.concat(orphan), state.old_cur + pair_count, state.new_cur + pair_count),
        emit(paired, state.cur_old_start, state.cur_new_start) | state.acc
      ]

      walk(rest, %{
        state
        | acc: acc,
          current: [],
          old_cur: post_old,
          new_cur: post_new,
          cur_old_start: post_old,
          cur_new_start: post_new
      })
    end
  end

  defp collect_run([{kind, _} = line | rest], dels, adds) when kind in [:del, :add] do
    {markers, rest} = Enum.split_while(rest, &match?({:other, _}, &1))

    case kind do
      :del -> collect_run(rest, [[line | markers] | dels], adds)
      :add -> collect_run(rest, dels, [[line | markers] | adds])
    end
  end

  defp collect_run(rest, dels, adds), do: {Enum.reverse(dels), Enum.reverse(adds), rest}

  defp emit(body, old_start, new_start) do
    old_count = Enum.count(body, &(elem(&1, 0) in [:context, :del]))
    new_count = Enum.count(body, &(elem(&1, 0) in [:context, :add]))
    text = Enum.map_join(body, &(elem(&1, 1) <> "\n"))
    "@@ -#{old_start},#{old_count} +#{new_start},#{new_count} @@\n#{text}"
  end
end
