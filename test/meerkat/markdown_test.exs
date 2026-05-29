defmodule Meerkat.MarkdownTest do
  use ExUnit.Case, async: true

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
end
