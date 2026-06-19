defmodule MeerkatWeb.VersionRestartTest do
  # async: false — mount reads the global `:meerkat, :review_state` and
  # the live-restart hook is captured via the global `:restart_fun`.
  use MeerkatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Meerkat.{Decision, ReviewState}

  @rs_file %{
    status: :modified,
    file_name: "src/widget.rs",
    old_file_name: nil,
    old_content: "fn a() {}\n",
    new_content: "fn a2() {}\n",
    hunks: ["@@ -1,1 +1,1 @@\n-fn a() {}\n+fn a2() {}"],
    read_errors: [],
    effective_oid: "",
    is_generated: false
  }

  setup do
    Decision.reset()
    prev_state = Application.get_env(:meerkat, :review_state)
    prev_restart = Application.fetch_env(:meerkat, :restart_fun)

    Application.put_env(:meerkat, :review_state, %ReviewState{files: [@rs_file]})
    test_pid = self()
    Application.put_env(:meerkat, :restart_fun, fn code -> send(test_pid, {:restart, code}) end)

    on_exit(fn ->
      if prev_state,
        do: Application.put_env(:meerkat, :review_state, prev_state),
        else: Application.delete_env(:meerkat, :review_state)

      case prev_restart do
        {:ok, val} -> Application.put_env(:meerkat, :restart_fun, val)
        :error -> Application.delete_env(:meerkat, :restart_fun)
      end
    end)

    :ok
  end

  test "live-restarts immediately when no comment form is open", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)

    send(view.pid, {:meerkat_version_available, "versions/v2"})

    assert_receive {:restart, 75}, 1000
  end

  test "defers the restart while a comment form is open, applies on close", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)

    render_hook(view, "comment_form.show_file", %{"file_index" => "0"})
    send(view.pid, {:meerkat_version_available, "versions/v2"})
    _ = render(view)

    refute_receive {:restart, _}, 200

    render_hook(view, "comment_form.hide", %{})
    assert_receive {:restart, 75}, 1000
  end
end
