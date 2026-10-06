defmodule Meerkat.Intraline do
  @moduledoc """
  Hunk pair-alignment for intra-line highlighting.

  `@git-diff-view` only runs fast-diff between paired `-` / `+` lines
  when the two sides of a `-`/`+` run have *equal* counts. A run with,
  say, 5 deletions and 4 additions — common when a wrapped source line
  gets joined or split — gets rendered plain on every pair, even though
  the first N of each side are trivially pairable.

  `split/1` walks each hunk and, whenever it finds a run whose deletion
  and addition counts differ, splits the hunk into:

    1. a **paired sub-hunk** containing the first `min(dels, adds)` of
       each. The library sees equal counts and runs intra-line diff on
       every pair.
    2. an **orphan sub-hunk** containing the remaining lines from the
       longer side. These still render plain — there is no paired
       counterpart to diff against.

  Context and already-matched runs pass through unchanged.
  """

  @doc """
  Split each hunk text in the list. Returns a flat list of hunk
  strings, possibly longer than the input.
  """
  @spec split([String.t()]) :: [String.t()]
  def split(hunks) when is_list(hunks), do: Enum.flat_map(hunks, &split_one/1)

  defp split_one(hunk) do
    case String.split(hunk, "\n", parts: 2) do
      [header, body_with_trailer] ->
        case parse_header(header) do
          {:ok, old_start, new_start} ->
            split_body(hunk, body_with_trailer, old_start, new_start)

          :error ->
            [hunk]
        end

      _ ->
        [hunk]
    end
  end

  defp parse_header("@@ " <> rest) do
    with [old_part, rest2] <- String.split(rest, " ", parts: 2),
         [new_part | _] <- String.split(rest2, " "),
         "-" <> old_body <- old_part,
         "+" <> new_body <- new_part,
         {old_start, _} <- Integer.parse(hd(String.split(old_body, ","))),
         {new_start, _} <- Integer.parse(hd(String.split(new_body, ","))) do
      {:ok, old_start, new_start}
    else
      _ -> :error
    end
  end

  defp parse_header(_), do: :error

  defp split_body(orig_hunk, body, old_start, new_start) do
    classified =
      body
      |> String.split("\n")
      |> drop_trailing_empty()
      |> Enum.map(&classify/1)

    state = %{
      acc: [],
      current: [],
      old_cur: old_start,
      new_cur: new_start,
      cur_old_start: old_start,
      cur_new_start: new_start
    }

    final = walk(classified, state)

    out =
      case final.current do
        [] ->
          Enum.reverse(final.acc)

        cur ->
          Enum.reverse([
            emit(Enum.reverse(cur), final.cur_old_start, final.cur_new_start) | final.acc
          ])
      end

    case out do
      [] -> [orig_hunk]
      _ -> out
    end
  end

  defp drop_trailing_empty([]), do: []

  defp drop_trailing_empty(list) do
    case List.last(list) do
      "" -> Enum.drop(list, -1)
      _ -> list
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

  defp walk([{tag, _} | _] = lines, state) when tag in [:del, :add] do
    {dels, adds, rest, post_old, post_new} =
      collect_run(lines, [], [], state.old_cur, state.new_cur)

    run_old_start = state.old_cur
    run_new_start = state.new_cur

    if length(dels) == length(adds) do
      merged_rev =
        Enum.reverse(Enum.map(adds, &{:add, &1})) ++
          Enum.reverse(Enum.map(dels, &{:del, &1}))

      walk(rest, %{
        state
        | current: merged_rev ++ state.current,
          old_cur: post_old,
          new_cur: post_new
      })
    else
      pair_count = min(length(dels), length(adds))

      paired_rev =
        Enum.reverse(Enum.map(Enum.take(adds, pair_count), &{:add, &1})) ++
          Enum.reverse(Enum.map(Enum.take(dels, pair_count), &{:del, &1}))

      flushed = paired_rev ++ state.current

      acc2 =
        case flushed do
          [] -> state.acc
          _ -> [emit(Enum.reverse(flushed), state.cur_old_start, state.cur_new_start) | state.acc]
        end

      orphan_old_ln = run_old_start + pair_count
      orphan_new_ln = run_new_start + pair_count

      orphan =
        Enum.map(Enum.drop(dels, pair_count), &{:del, &1}) ++
          Enum.map(Enum.drop(adds, pair_count), &{:add, &1})

      {orphan_extra, rest2} = take_others(rest, [])
      orphan_full = orphan ++ orphan_extra

      acc3 =
        case orphan_full do
          [] -> acc2
          _ -> [emit(orphan_full, orphan_old_ln, orphan_new_ln) | acc2]
        end

      walk(rest2, %{
        state
        | acc: acc3,
          current: [],
          old_cur: post_old,
          new_cur: post_new,
          cur_old_start: post_old,
          cur_new_start: post_new
      })
    end
  end

  defp collect_run([{:del, s} | rest], dels, adds, old_c, new_c),
    do: collect_run(rest, [s | dels], adds, old_c + 1, new_c)

  defp collect_run([{:add, s} | rest], dels, adds, old_c, new_c),
    do: collect_run(rest, dels, [s | adds], old_c, new_c + 1)

  defp collect_run(rest, dels, adds, old_c, new_c),
    do: {Enum.reverse(dels), Enum.reverse(adds), rest, old_c, new_c}

  defp take_others([{:other, s} | rest], acc), do: take_others(rest, [{:other, s} | acc])
  defp take_others(rest, acc), do: {Enum.reverse(acc), rest}

  defp classify(<<" ", _::binary>> = line), do: {:context, line}
  defp classify(<<"-", _::binary>> = line), do: {:del, line}
  defp classify(<<"+", _::binary>> = line), do: {:add, line}
  defp classify(line), do: {:other, line}

  defp emit(body, old_start, new_start) do
    {old_count, new_count, text_rev} =
      Enum.reduce(body, {0, 0, []}, fn
        {:context, s}, {o, n, acc} -> {o + 1, n + 1, [s | acc]}
        {:del, s}, {o, n, acc} -> {o + 1, n, [s | acc]}
        {:add, s}, {o, n, acc} -> {o, n + 1, [s | acc]}
        {:other, s}, {o, n, acc} -> {o, n, [s | acc]}
      end)

    body_text = text_rev |> Enum.reverse() |> Enum.join("\n")
    "@@ -#{old_start},#{old_count} +#{new_start},#{new_count} @@\n#{body_text}\n"
  end
end
