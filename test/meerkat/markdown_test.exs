defmodule Meerkat.MarkdownTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Meerkat.Markdown

  describe "to_safe_html/1 — empty input" do
    test "nil returns empty string" do
      assert Markdown.to_safe_html(nil) == ""
    end

    test "empty string returns empty string (no wrapper paragraph)" do
      assert Markdown.to_safe_html("") == ""
    end
  end

  describe "to_safe_html/1 — basic markdown" do
    test "renders bold" do
      assert Markdown.to_safe_html("**bold**") =~ "<strong>bold</strong>"
    end

    test "renders fenced code" do
      html = Markdown.to_safe_html("```\ncode\n```")
      assert html =~ "<pre>"
      assert html =~ "<code"
    end

    test "renders list" do
      html = Markdown.to_safe_html("- one\n- two\n")
      assert html =~ "<ul>"
      assert html =~ "<li>"
      assert html =~ "one"
      assert html =~ "two"
    end
  end

  # XSS coverage. Markdown.to_safe_html/1 is the sole sanitiser
  # between agent-typed markdown and rendered HTML in the browser,
  # so every common vector that reaches a render path needs a
  # regression pin. A vector is "neutralised" iff its executable
  # form (an inline `<script>` element, a `javascript:` URL, an
  # `on*=` event-handler attribute) does NOT appear in the output.
  describe "to_safe_html/1 — XSS vectors" do
    test "strips inline <script>" do
      html = Markdown.to_safe_html("<script>alert(1)</script>")
      refute html =~ ~r/<script/i
    end

    test "strips <script> with mixed casing" do
      html = Markdown.to_safe_html("<ScRiPt>alert(1)</ScRiPt>")
      refute html =~ ~r/<script/i
    end

    test "strips <iframe>" do
      html = Markdown.to_safe_html("<iframe src=\"javascript:alert(1)\"></iframe>")
      refute html =~ ~r/<iframe/i
      refute html =~ ~r/javascript:/i
    end

    test "strips javascript: in markdown link" do
      html = Markdown.to_safe_html("[click](javascript:alert(1))")
      refute html =~ ~r/javascript:/i
    end

    test "strips javascript: in raw <a> href" do
      html = Markdown.to_safe_html("<a href=\"javascript:alert(1)\">x</a>")
      refute html =~ ~r/javascript:/i
    end

    test "strips onerror on <img>" do
      html = Markdown.to_safe_html("<img src=x onerror=\"alert(1)\">")
      refute html =~ ~r/onerror/i
    end

    test "strips onmouseover on inline element" do
      html = Markdown.to_safe_html("<span onmouseover=\"alert(1)\">x</span>")
      refute html =~ ~r/onmouseover/i
    end

    test "strips onload on <body> in raw HTML" do
      html = Markdown.to_safe_html("<body onload=\"alert(1)\"></body>")
      refute html =~ ~r/onload/i
    end

    test "strips inline SVG with onload" do
      html = Markdown.to_safe_html("<svg onload=\"alert(1)\"></svg>")
      refute html =~ ~r/onload/i
    end

    test "strips <object data=javascript:>" do
      html = Markdown.to_safe_html("<object data=\"javascript:alert(1)\"></object>")
      refute html =~ ~r/javascript:/i
    end

    test "strips <embed src=javascript:>" do
      html = Markdown.to_safe_html("<embed src=\"javascript:alert(1)\">")
      refute html =~ ~r/javascript:/i
    end

    test "strips data: URLs that point at scriptable types" do
      html = Markdown.to_safe_html("<a href=\"data:text/html,<script>alert(1)</script>\">x</a>")
      refute html =~ ~r/<script/i
    end

    test "strips <style> blocks" do
      html = Markdown.to_safe_html("<style>body{}</style>plain")
      refute html =~ ~r/<style/i
    end

    test "strips inline style with expression / url(javascript:)" do
      input = "<div style=\"background:url(javascript:alert(1))\">x</div>"
      html = Markdown.to_safe_html(input)
      refute html =~ ~r/javascript:/i
    end

    test "preserves plain text adjacent to stripped tags" do
      html = Markdown.to_safe_html("safe text <script>alert(1)</script> more text")
      assert html =~ "safe text"
      assert html =~ "more text"
      refute html =~ ~r/<script/i
    end
  end

  describe "to_safe_html/1 warning block" do
    test "unclosed code fence still renders best-effort html" do
      # Drive Earmark's `{:error, html, warnings}` branch with an
      # unclosed code fence — the path that exists to render
      # best-effort html plus a `.md-warn` summary so the author
      # isn't left wondering why their text looks weird.
      html = Markdown.to_safe_html("```elixir\nno closing fence\n")
      assert is_binary(html)
      assert html =~ "no closing fence"

      # `.md-warn` block is the contract when warnings fire; some
      # earmark versions don't warn here, but if it DOES warn, the
      # block must contain the canonical summary header.
      if html =~ "md-warn" do
        assert html =~ "Markdown parse warnings"
      end
    end
  end

  describe "render_diff_sides/3 — tinting" do
    test "changed paragraph: removed block tinted on old side, added on new" do
      old = "# Title\n\nOld para.\n\nShared.\n"
      new = "# Title\n\nNew para.\n\nShared.\n"
      %{old_html: o, new_html: n} = Markdown.render_diff_sides(old, new, :modified)

      assert o =~ ~r/<div class="md-del">.*Old para\..*<\/div>/s
      refute o =~ "md-ins"
      assert n =~ ~r/<div class="md-ins">.*New para\..*<\/div>/s
      refute n =~ "md-del"
    end

    test "unchanged blocks are not tinted on either side" do
      src = "# Title\n\nUnchanged paragraph.\n"
      %{old_html: o, new_html: n} = Markdown.render_diff_sides(src, src, :modified)

      assert o =~ "Unchanged paragraph."
      assert n =~ "Unchanged paragraph."
      refute o =~ "md-del"
      refute o =~ "md-ins"
      refute n =~ "md-del"
      refute n =~ "md-ins"
    end

    test "added-only block appears tinted on new side only" do
      old = "Shared.\n"
      new = "Shared.\n\nBrand new.\n"
      %{old_html: o, new_html: n} = Markdown.render_diff_sides(old, new, :modified)

      refute o =~ "Brand new."
      assert n =~ ~r/<div class="md-ins">.*Brand new\..*<\/div>/s
    end

    test "deleted-only block is tinted on the old side and absent from the new" do
      old = "Shared.\n\nGone forever.\n"
      new = "Shared.\n"
      %{old_html: o, new_html: n} = Markdown.render_diff_sides(old, new, :modified)

      assert o =~ ~r/<div class="md-del">.*Gone forever\..*<\/div>/s
      refute n =~ "Gone forever."
      refute n =~ "md-del"
    end
  end

  describe "render_diff_sides/3 — status drives which sides render" do
    test "added file has no old side" do
      assert %{old_html: nil, new_html: new} =
               Markdown.render_diff_sides("", "# New\n\nbody\n", :added)

      assert new =~ "New"
    end

    test "deleted file has no new side" do
      assert %{old_html: old, new_html: nil} =
               Markdown.render_diff_sides("# Gone\n\nbody\n", "", :deleted)

      assert old =~ "Gone"
    end
  end

  describe "render_diff_sides/3 — document semantics" do
    test "a lone newline is not a <br> (unlike comment rendering)" do
      src = "line one\nline two\n"
      %{new_html: n} = Markdown.render_diff_sides("", src, :added)
      refute n =~ "<br"
      # The comment path keeps breaks:true, so it WOULD insert a <br>.
      assert Markdown.to_safe_html(src) =~ "<br"
    end

    test "a fenced code block containing a blank line is not split" do
      # A naive blank-line block split would shred the fence into two
      # half-open blocks; the whole fence must stay one block so it
      # renders as a single <pre><code>.
      code = "```elixir\nx = 1\n\ny = 2\n```\n"
      src = "intro\n\n" <> code
      %{new_html: n} = Markdown.render_diff_sides("", src, :added)

      assert Regex.scan(~r/<pre>/, n) |> length() == 1
      assert n =~ "x = 1"
      assert n =~ "y = 2"
    end

    test "a different fence marker inside a fence does not close it" do
      # A ``` fence stays open across a ~~~ line: the close must match
      # the opener's marker type, else the trailing blank line would be
      # read as a block boundary and shred the code block.
      src = "```\nbefore\n~~~\n\nafter\n```\n"
      %{new_html: n} = Markdown.render_diff_sides("", src, :added)

      assert Regex.scan(~r/<pre>/, n) |> length() == 1
      assert n =~ "before"
      assert n =~ "after"
    end
  end

  describe "render_diff_sides/3 — XSS still neutralised" do
    test "script / onerror / javascript: stripped from both sides" do
      payload =
        "<script>alert(1)</script>\n\n[x](javascript:alert(1))\n\n<img src=x onerror=alert(1)>\n"

      %{old_html: o, new_html: n} = Markdown.render_diff_sides(payload, payload, :modified)

      for html <- [o, n] do
        refute html =~ ~r/<script/i
        refute html =~ ~r/javascript:/i
        refute html =~ ~r/onerror/i
      end
    end
  end

  describe "render_diff_sides/3 — properties" do
    # A markdown block: a heading, paragraph, or list — no blank lines
    # inside, so it stays one block through the splitter.
    defp block_gen do
      text = string(:alphanumeric, min_length: 1, max_length: 12)

      one_of([
        map(text, &("# " <> &1)),
        map(text, & &1),
        map(text, &("- " <> &1))
      ])
    end

    property "rendered output never contains an executable <script tag" do
      check all(
              blocks <- list_of(block_gen(), min_length: 1, max_length: 6),
              injected = Enum.intersperse(blocks ++ ["<script>alert(1)</script>"], "\n\n"),
              src = Enum.join(injected)
            ) do
        %{old_html: o, new_html: n} = Markdown.render_diff_sides(src, src, :modified)
        refute o =~ ~r/<script/i
        refute n =~ ~r/<script/i
      end
    end

    property "every unchanged block's text survives into both sides" do
      check all(blocks <- list_of(block_gen(), min_length: 1, max_length: 6)) do
        src = Enum.join(blocks, "\n\n") <> "\n"
        %{old_html: o, new_html: n} = Markdown.render_diff_sides(src, src, :modified)

        for block <- blocks do
          word = block |> String.replace(~r/^[#\-]\s*/, "") |> String.trim()

          if word != "" do
            assert o =~ word
            assert n =~ word
          end
        end
      end
    end
  end
end
