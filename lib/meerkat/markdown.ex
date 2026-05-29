defmodule Meerkat.Markdown do
  @moduledoc """
  Render comment bodies (markdown source) to safe HTML.

  Pipeline: earmark parses GFM, html_sanitize_ex strips `<script>` /
  event handlers / `javascript:` URLs / other XSS vectors.
  """

  @doc """
  Render `body` to HTML safe for `Phoenix.HTML.raw/1`. Empty input
  returns an empty string (no `<p></p>` wrapper). On a recoverable
  parse error (`{:error, html, warnings}` from earmark — unclosed
  fence, malformed table, bad reference link), the best-effort HTML
  is prefixed with a small `.md-warn` block listing the warnings so
  the author isn't left wondering why their text renders weird.
  """
  @spec to_safe_html(String.t() | nil) :: String.t()
  def to_safe_html(nil), do: ""
  def to_safe_html(""), do: ""

  def to_safe_html(body) do
    case Earmark.as_html(body, %Earmark.Options{gfm: true, breaks: true}) do
      {:ok, html, _warnings} ->
        HtmlSanitizeEx.markdown_html(html)

      {:error, html, warnings} ->
        warn_block(warnings) <> HtmlSanitizeEx.markdown_html(html)
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
