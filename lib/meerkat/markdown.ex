defmodule Meerkat.Markdown do
  @moduledoc """
  Render markdown to safe HTML — comment bodies and, for the per-file
  rendered view, whole `.md` files as a side-by-side Old/New diff.

  Pipeline: earmark parses GFM, html_sanitize_ex strips `<script>` /
  event handlers / `javascript:` URLs / other XSS vectors.
  """

  @doc """
  Render a comment `body` to HTML safe for `Phoenix.HTML.raw/1`. Empty
  input returns an empty string (no `<p></p>` wrapper). On a recoverable
  parse error (`{:error, html, warnings}` from earmark — unclosed
  fence, malformed table, bad reference link), the best-effort HTML
  is prefixed with a small `.md-warn` block listing the warnings so
  the author isn't left wondering why their text renders weird. A lone
  newline renders as a line break (`breaks: true`).
  """
  @spec to_safe_html(String.t() | nil) :: String.t()
  def to_safe_html(nil), do: ""
  def to_safe_html(""), do: ""

  def to_safe_html(body) do
    {warn, html} = render_fragment(body, breaks: true)
    warn <> html
  end

  @doc """
  Render `old_source` and `new_source` (a markdown file's two sides) to
  safe HTML for the side-by-side rendered view, tinting changed blocks.

  Returns `%{old_html: ..., new_html: ...}`, each safe for
  `Phoenix.HTML.raw/1`. `status: :added` omits the old side
  (`old_html: nil`); `:deleted` omits the new side. Blocks present on
  one side only are wrapped in `<div class="md-del">` (old) /
  `<div class="md-ins">` (new). Tinting is per markdown block, so a
  one-word edit tints the whole paragraph.
  """
  @spec render_diff_sides(String.t(), String.t(), atom()) ::
          %{old_html: String.t() | nil, new_html: String.t() | nil}
  def render_diff_sides(old_source, new_source, status)
      when is_binary(old_source) and is_binary(new_source) do
    old_blocks = split_blocks(old_source)
    new_blocks = split_blocks(new_source)
    diff = List.myers_difference(old_blocks, new_blocks)

    %{
      old_html: if(status == :added, do: nil, else: render_side(diff, :old)),
      new_html: if(status == :deleted, do: nil, else: render_side(diff, :new))
    }
  end

  # Render one side of the block diff. The old side keeps `:eq` + `:del`
  # blocks (deletions tinted red); the new side keeps `:eq` + `:ins`
  # blocks (insertions tinted green). `:eq` blocks render bare on both
  # sides so unchanged prose looks identical left and right.
  defp render_side(diff, side) do
    {changed_op, changed_class} =
      case side do
        :old -> {:del, "md-del"}
        :new -> {:ins, "md-ins"}
      end

    diff
    |> Enum.flat_map(fn
      {:eq, blocks} -> Enum.map(blocks, &{:eq, &1})
      {^changed_op, blocks} -> Enum.map(blocks, &{:changed, &1})
      {_other_op, _blocks} -> []
    end)
    |> Enum.map_join("\n", fn
      {:eq, block} -> render_block(block)
      {:changed, block} -> ~s(<div class="#{changed_class}">) <> render_block(block) <> "</div>"
    end)
  end

  # Render a single block of markdown source to sanitized HTML, dropping
  # the parse-warning prefix (a whole-file render surfaces nothing
  # actionable per-block, and the source is the diff itself).
  defp render_block(block) do
    {_warn, html} = render_fragment(block, breaks: false)
    html
  end

  # Shared earmark → sanitize step. Returns `{warn_block, html}` so the
  # comment path can prepend parse warnings and the file path can drop
  # them. `breaks` selects comment (true) vs document (false) newline
  # handling.
  defp render_fragment(source, breaks: breaks) do
    case Earmark.as_html(source, %Earmark.Options{gfm: true, breaks: breaks}) do
      {:ok, html, _warnings} ->
        {"", HtmlSanitizeEx.markdown_html(html)}

      {:error, html, warnings} ->
        {warn_block(warnings), HtmlSanitizeEx.markdown_html(html)}
    end
  end

  # Split markdown source into top-level blocks on blank lines, but
  # keep fenced code blocks (``` / ~~~) intact: a blank line inside a
  # fence is content, not a block boundary. Without this a code block
  # containing a blank line would be shredded into separate blocks and
  # render as broken (half-open) fences.
  defp split_blocks(source) do
    source
    |> String.split("\n")
    |> group_lines()
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  # Fold lines into blocks. `fence` holds the open fence marker (```` or
  # ~~~ prefix) while inside a code block; a blank line only ends the
  # current block when no fence is open.
  defp group_lines(lines) do
    {blocks, current, _fence} =
      Enum.reduce(lines, {[], [], nil}, fn line, {blocks, current, fence} ->
        cond do
          fence != nil ->
            if fence_close?(line, fence),
              do: {blocks, [line | current], nil},
              else: {blocks, [line | current], fence}

          (marker = fence_open(line)) != nil ->
            {blocks, [line | current], marker}

          String.trim(line) == "" ->
            {flush(blocks, current), [], nil}

          true ->
            {blocks, [line | current], nil}
        end
      end)

    flush(blocks, current) |> Enum.reverse()
  end

  defp flush(blocks, []), do: blocks
  defp flush(blocks, current), do: [current |> Enum.reverse() |> Enum.join("\n") | blocks]

  # A fence opens when a line is `` ``` `` or `~~~` (3+) optionally
  # indented and with an info string. Returns the bare marker char run
  # so the close can require the same fence type.
  defp fence_open(line) do
    case Regex.run(~r/^\s{0,3}(`{3,}|~{3,})/, line) do
      [_, marker] -> marker
      _ -> nil
    end
  end

  # A fence closes on a line of the same marker type, length >= the
  # opener, and no trailing info string (CommonMark close rule, relaxed).
  defp fence_close?(line, fence) do
    char = String.first(fence)

    case Regex.run(~r/^\s{0,3}([`~]{3,})\s*$/, line) do
      [_, marker] ->
        String.first(marker) == char and String.length(marker) >= String.length(fence)

      _ ->
        false
    end
  end

  defp warn_block([]), do: ""

  defp warn_block(warnings) do
    items =
      warnings
      |> Enum.map(fn
        {_line, _type, msg} when is_binary(msg) -> msg
        {_line, msg} when is_binary(msg) -> msg
        msg when is_binary(msg) -> msg
        other -> inspect(other)
      end)
      |> Enum.map_join("", fn msg -> "<li>" <> HtmlSanitizeEx.basic_html(msg) <> "</li>" end)

    ~s(<div class="md-warn" role="note"><strong>Markdown parse warnings:</strong><ul>) <>
      items <> "</ul></div>"
  end
end
