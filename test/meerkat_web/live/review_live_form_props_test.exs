defmodule MeerkatWeb.ReviewLiveFormPropsTest do
  # The frontend resolves the suggestion editor/fence language from
  # the `fileName` form prop, so file and inline forms must carry it.
  # async: false — mount reads the global `:meerkat, :review_state`
  # and the singleton `Meerkat.Decision`.
  use MeerkatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Meerkat.{Decision, ReviewState}

  @rs_file %{
    status: :modified,
    file_name: "src/widget.rs",
    old_file_name: nil,
    old_content: "fn a() {}\nfn b() {}\n",
    new_content: "fn a2() {}\nfn b() {}\n",
    hunks: ["@@ -1,2 +1,2 @@\n-fn a() {}\n+fn a2() {}\n fn b() {}"],
    read_errors: [],
    effective_oid: "",
    is_generated: false
  }

  setup do
    Decision.reset()
    prev = Application.get_env(:meerkat, :review_state)
    Application.put_env(:meerkat, :review_state, %ReviewState{files: [@rs_file]})
    on_exit(fn -> restore(:review_state, prev) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:meerkat, key)
  defp restore(key, val), do: Application.put_env(:meerkat, key, val)

  test "file comment form carries the file's name", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)

    html = render_hook(view, "comment_form.show_file", %{"file_index" => "0"})
    assert html =~ ~s(&quot;fileName&quot;:&quot;src/widget.rs&quot;)
  end

  test "inline comment form carries the file's name", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)

    html =
      render_hook(view, "comment_form.show_at_line", %{
        "file_index" => "0",
        "start_line" => "1",
        "end_line" => "1",
        "side" => "new"
      })

    assert html =~ ~s(&quot;fileName&quot;:&quot;src/widget.rs&quot;)
  end
end
