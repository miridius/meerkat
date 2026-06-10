defmodule MeerkatWeb.ReviewLiveRenderedTest do
  # The per-file markdown Diff⇄Rendered toggle. Mounts ReviewLive in
  # "unbound" mode (state injected via app env, no ReviewServer) so the
  # toggle — pure socket state — can be driven with render_click. async:
  # false because the mount reads the global `:meerkat, :review_state`
  # and the singleton `Meerkat.Decision`.
  use MeerkatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Meerkat.{Decision, ReviewState}

  @md_file %{
    status: :modified,
    file_name: "README.md",
    old_file_name: nil,
    old_content: "# Title\n\nOld paragraph.\n",
    new_content: "# Title\n\nNew paragraph.\n",
    hunks: ["@@ -1,3 +1,3 @@\n # Title\n \n-Old paragraph.\n+New paragraph."],
    read_errors: [],
    effective_oid: "",
    is_generated: false
  }

  setup do
    # A prior test may have left a submitted decision, which makes
    # ReviewLive mount the done view instead of the review.
    Decision.reset()
    prev = Application.get_env(:meerkat, :review_state)
    Application.put_env(:meerkat, :review_state, %ReviewState{files: [@md_file]})
    on_exit(fn -> restore(:review_state, prev) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:meerkat, key)
  defp restore(key, val), do: Application.put_env(:meerkat, key, val)

  test "toggling Rendered swaps the diff for the rendered preview and back", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)

    assert has_element?(view, "#DiffViewer-0")
    refute has_element?(view, ".md-preview")

    html =
      view
      |> element("button.md-view-toggle[phx-value-file_name='README.md']")
      |> render_click()

    assert html =~ "md-preview"
    assert html =~ ~s(<div class="md-ins">)
    assert html =~ ~s(<div class="md-del">)
    refute has_element?(view, "#DiffViewer-0")

    view
    |> element("button.md-view-toggle[phx-value-file_name='README.md']")
    |> render_click()

    assert has_element?(view, "#DiffViewer-0")
    refute has_element?(view, ".md-preview")
  end

  test "non-markdown files have no rendered toggle", %{conn: conn} do
    code_file = %{@md_file | file_name: "main.rs"}
    Application.put_env(:meerkat, :review_state, %ReviewState{files: [code_file]})

    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)
    refute has_element?(view, "button.md-view-toggle")
  end

  test "an added markdown file renders a single New pane", %{conn: conn} do
    added = %{@md_file | status: :added, old_content: "", new_content: "# Fresh\n\nbody\n"}
    Application.put_env(:meerkat, :review_state, %ReviewState{files: [added]})

    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)
    view |> element("button.md-view-toggle") |> render_click()

    assert has_element?(view, ".md-grid.single")
    assert has_element?(view, "figcaption.md-side-head", "New")
    refute has_element?(view, "figcaption.md-side-head", "Old")
  end

  test "read_errors surface as a banner in the rendered view", %{conn: conn} do
    errs = %{@md_file | read_errors: ["git show HEAD:README.md failed: bad object"]}
    Application.put_env(:meerkat, :review_state, %ReviewState{files: [errs]})

    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)
    html = view |> element("button.md-view-toggle") |> render_click()

    assert html =~ "md-read-errors"
    assert html =~ "do not approve"
    assert html =~ "bad object"
  end

  test "toggling an unknown file_name no-ops (no blank pane)", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)

    html = render_click(view, "file.toggle_rendered", %{"file_name" => "ghost.md"})

    refute html =~ "md-preview"
    assert has_element?(view, "#DiffViewer-0")
  end
end
