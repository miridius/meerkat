defmodule Meerkat.Markdown.Scrubber do
  @moduledoc """
  html_sanitize_ex's `MarkdownHTML` scrubber, plus every link it keeps
  opening in a new tab, so a click never navigates away from the
  review page. `HtmlSanitizeEx.Scrubber.scrub/2` calls only
  `before_scrub/1` and `scrub/1`.
  """

  alias HtmlSanitizeEx.Scrubber.MarkdownHTML

  @new_tab [{"target", "_blank"}, {"rel", "noopener noreferrer"}]

  defdelegate before_scrub(html), to: MarkdownHTML

  def scrub(node) do
    case MarkdownHTML.scrub(node) do
      {"a", attributes, children} ->
        kept = Enum.reject(attributes, fn {name, _} -> name in ["target", "rel"] end)
        {"a", kept ++ @new_tab, children}

      scrubbed ->
        scrubbed
    end
  end
end
