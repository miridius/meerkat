defmodule Meerkat.Cljfmt do
  @moduledoc """
  Formats a Clojure suggestion as it would sit in its file, with
  `clj-paren-repair-claude-hook` from bhauman's clojure-mcp-light:
  parinfer repairs unbalanced delimiters, then cljfmt formats. The
  hook applies the cljfmt config of the directory it runs in only
  when cljfmt's defaults would also change the file.

  The hook works on a file, so the suggestion is joined with the file
  around it, `above` and `below`, and cut back out. A suggestion
  that can't be formatted, or cut back out, comes back as it was.
  """

  @hook "clj-paren-repair-claude-hook"

  # Whitespace, which cljfmt's indentation adds or removes.
  @whitespace ~r/[\s,]/u

  @doc """
  The text of `source` around its lines `start_line..end_line`
  (1-based, inclusive): `above` ends with a line break and `below`
  starts with one, unless empty.
  """
  @spec context(String.t(), pos_integer(), pos_integer()) :: {String.t(), String.t()}
  def context(source, start_line, end_line) do
    lines = String.split(source, "\n")

    {lines |> Enum.take(start_line - 1) |> Enum.map_join(&(&1 <> "\n")),
     lines |> Enum.drop(end_line) |> Enum.map_join(&("\n" <> &1))}
  end

  @doc """
  `code` repaired and formatted as it would sit between `above` and
  `below`, by the hook run in `cwd`.
  """
  @spec format(String.t(), String.t(), String.t(), Path.t()) :: String.t()
  def format(code, above, below, cwd) do
    format_with(code, above, below, &run_hook(cwd, &1, &2))
  end

  # Test seam: `run.(path, cljfmt?)` rewrites the file at `path`,
  # repairing its delimiters, and with `cljfmt?` formatting it.
  @doc false
  def format_with(code, above, below, run) do
    path = Meerkat.TmpPath.unique("meerkat-cljfmt") <> ".clj"

    try do
      # Parinfer keeps every line, so the repaired suggestion is what
      # lies between the unchanged lines around it.
      repaired = through(run, path, false, above <> code <> below)

      with {:ok, repaired_code} <- between(repaired, above, below),
           formatted = through(run, path, true, above <> repaired_code <> below),
           {:ok, lines} <- cut(formatted, above, repaired_code, below) do
        Enum.join(lines, "\n")
      else
        _ -> code
      end
    after
      File.rm(path)
    end
  end

  defp through(run, path, cljfmt?, text) do
    File.write!(path, text)
    run.(path, cljfmt?)
    File.read!(path)
  end

  defp between(text, above, below) do
    size = byte_size(text) - byte_size(above) - byte_size(below)

    if String.starts_with?(text, above) and String.ends_with?(text, below),
      do: {:ok, binary_part(text, byte_size(above), size)},
      else: :error
  end

  # When cljfmt changed only whitespace, which the first clause checks,
  # the suggestion's lines in `formatted` are those holding its
  # non-whitespace characters. They must hold none of the text around
  # it.
  defp cut(formatted, above, code, below) do
    first = significant(above)
    last = first + significant(code)

    {lines, _} =
      formatted
      |> String.split("\n")
      |> Enum.map_reduce(0, fn line, seen ->
        next = seen + significant(line)
        {{line, seen, next}, next}
      end)

    picked = Enum.filter(lines, fn {_, from, to} -> from < last and to > first end)

    with true <- strip(formatted) == strip(above <> code <> below),
         [{_, ^first, _} | _] <- picked,
         # muex:ignore equivalent: swapping the tuple's first two elements swaps `_` with `_`
         {_, _, ^last} <- List.last(picked) do
      {:ok,
       blank_lines(code, &Enum.take_while/2) ++
         Enum.map(picked, &elem(&1, 0)) ++
         blank_lines(code, &take_last_while/2)}
    else
      _ -> :error
    end
  end

  # The blank lines `take` finds at an end of `code`, which hold no
  # character to find them by in the formatted text.
  defp blank_lines(code, take) do
    code |> String.split("\n") |> take.(&(String.trim(&1) == "")) |> Enum.map(fn _ -> "" end)
  end

  defp take_last_while(list, fun), do: list |> Enum.reverse() |> Enum.take_while(fun)

  defp significant(text), do: text |> strip() |> String.length()

  defp strip(text), do: String.replace(text, @whitespace, "")

  # The hook reads a Claude Code PostToolUse payload for an edit of
  # `path` on stdin. System.cmd can't write to stdin, so `sh` redirects
  # a tmp file of the payload onto it.
  defp run_hook(cwd, path, cljfmt?) do
    payload = path <> ".json"

    File.write!(
      payload,
      Jason.encode!(%{
        hook_event_name: "PostToolUse",
        tool_name: "Edit",
        tool_input: %{file_path: path},
        tool_response: %{},
        session_id: "meerkat"
      })
    )

    flags = if cljfmt?, do: ["--no-revert", "--cljfmt"], else: ["--no-revert"]

    try do
      case System.cmd(
             "/bin/sh",
             ["-c", ~s(exec "$0" "$@" < "$MEERKAT_HOOK_PAYLOAD"), @hook | flags],
             env: [{"MEERKAT_HOOK_PAYLOAD", payload}],
             cd: cwd,
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          :ok

        {output, code} ->
          IO.puts(:stderr, "meerkat: #{@hook} exited #{code}: #{String.trim(output)}")
      end
    after
      File.rm(payload)
    end
  end
end
