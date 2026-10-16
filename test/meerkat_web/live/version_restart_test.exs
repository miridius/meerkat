defmodule MeerkatWeb.VersionRestartTest do
  # async: false: mount reads the global `:meerkat, :review_state` and
  # the live-restart hook is captured via the global `:restart_fun`.
  use MeerkatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Meerkat.ReviewState

  @rs_file %{
    status: :modified,
    file_name: "src/widget.rs",
    old_file_name: nil,
    old_content: "fn a() {}\n",
    new_content: "fn a2() {}\n",
    hunks: ["@@ -1,1 +1,1 @@\n-fn a() {}\n+fn a2() {}"],
    additions: 1,
    deletions: 1,
    read_errors: [],
    effective_oid: "",
    is_generated: false
  }

  setup do
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

    assert_receive {:restart, 75}
  end

  test "defers the restart while a comment form is open, applies on close", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)

    render_hook(view, "comment_form.show_file", %{"file_index" => "0"})
    send(view.pid, {:meerkat_version_available, "versions/v2"})
    _ = render(view)

    refute_receive {:restart, _}, 200

    render_hook(view, "comment_form.hide", %{"form_key" => "file:0"})
    assert_receive {:restart, 75}
  end

  test "with two forms open, the restart waits for the last one to close", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)

    render_hook(view, "comment_form.show_file", %{"file_index" => "0"})
    render_hook(view, "comment_form.show_global", %{})
    send(view.pid, {:meerkat_version_available, "versions/v2"})
    _ = render(view)

    render_hook(view, "comment_form.hide", %{"form_key" => "file:0"})
    refute_receive {:restart, _}, 200

    render_hook(view, "comment_form.hide", %{"form_key" => "global"})
    assert_receive {:restart, 75}
  end

  test "does not live-restart once a decision has been submitted", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)

    # Reviewer approves; the CLI is now in its post-decision halt window
    # (Decision.current() is set, the BEAM about to exit 0). A version
    # landing now must not preempt that exit code with a restart (75).
    render_hook(view, "decision.approve", %{})
    send(view.pid, {:meerkat_version_available, "versions/v2"})
    _ = render(view)

    refute_receive {:restart, _}, 300
  end

  test "applies a deferred update when a state push clears the open form", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)

    render_hook(view, "comment_form.show_file", %{"file_index" => "0"})
    send(view.pid, {:meerkat_version_available, "versions/v2"})
    _ = render(view)
    refute_receive {:restart, _}, 200

    # A cross-tab state push that carries no open form should apply the
    # deferred restart (change_open_forms is not the only path into the gate).
    send(view.pid, {:state_changed, %ReviewState{files: [@rs_file]}})
    assert_receive {:restart, 75}
  end

  test "a connected mount registers the LiveView as a viewer", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)
    assert Registry.keys(Meerkat.ViewerRegistry, view.pid) == [:viewer]
  end

  test "a tab reconnecting with assets the server still serves stays put", %{conn: conn} do
    conn =
      put_connect_params(conn, %{
        "_track_static" => ["http://127.0.0.1:4002/assets/app-current.js"]
      })

    assert {:ok, _view, _html} = live_isolated(conn, MeerkatWeb.ReviewLive)
  end

  test "a tab reconnecting with assets the server no longer serves reloads", %{conn: conn} do
    conn =
      put_connect_params(conn, %{"_track_static" => ["http://127.0.0.1:4002/assets/app-old.js"]})

    assert {:error, {:redirect, %{to: "/"}}} = live_isolated(conn, MeerkatWeb.ReviewLive)
  end

  # A build replaced after boot must not change the page's tags, or they
  # would disagree with the assets static_changed?/1 checks, and every
  # reconnect would redirect again.
  test "a page's asset tags come from the manifest the endpoint loaded at boot", %{conn: conn} do
    manifest =
      PhoenixVite.Manifest.parse(
        ~s({"js/app.js": {"file": "assets/app-booted.js", "css": ["assets/app-booted.css"], "isEntry": true}})
      )

    put_endpoint_config(vite_manifest: manifest)
    html = conn |> get("/") |> html_response(200)

    assert html =~ "assets/app-booted.js"
    assert html =~ "assets/app-booted.css"
  end

  # Browsers don't scope cookies by port, so another review's cookie must
  # not replace the one this review's tab rejoins with.
  test "a page's session cookie is named for the review's port", %{conn: conn} do
    put_endpoint_config(
      vite_manifest: PhoenixVite.Manifest.parse(~s({"js/app.js": {"file": "a.js"}}))
    )

    conn = conn |> Map.put(:port, 4321) |> get("/")

    assert Map.keys(conn.resp_cookies) == ["_meerkat_key_4321"]
  end

  test "a tab's socket reads the session cookie named for the port the review bound" do
    bound = fn :http -> {:ok, {{127, 0, 0, 1}, 4321}} end

    named =
      for {"/live", Phoenix.LiveView.Socket, opts} <- MeerkatWeb.Endpoint.__sockets__(),
          transport <- [:websocket, :longpoll] do
        {m, f, a} = opts[transport][:connect_info][:session]
        apply(m, f, a ++ [bound])
      end

    assert named == List.duplicate(MeerkatWeb.Endpoint.session_options(4321), 2)

    assert MeerkatWeb.Endpoint.session_options(4321)[:key] == "_meerkat_key_4321"
  end

  test "with no server bound, a socket's session options can't be named" do
    assert_raise MatchError, fn -> MeerkatWeb.Endpoint.socket_session_options() end
  end

  # Replaces the endpoint's config for this test, merging in `changes`.
  defp put_endpoint_config(changes) do
    old = Keyword.delete(:ets.tab2list(MeerkatWeb.Endpoint), :__config__)
    new = Enum.reject(old, fn {key, _} -> List.keymember?(changes, key, 0) end) ++ changes
    MeerkatWeb.Endpoint.config_change([{MeerkatWeb.Endpoint, new}], [])
    on_exit(fn -> MeerkatWeb.Endpoint.config_change([{MeerkatWeb.Endpoint, old}], []) end)
  end
end
