defmodule MeerkatWeb.ReviewLiveEventsCase do
  @moduledoc """
  Shared setup and helpers for the tests that drive `MeerkatWeb.ReviewLive`'s
  event handlers hermetically: unbound mode injects state via app env; bound
  mode starts a real ReviewServer against a throwaway `git init` dir so the
  delegation branches (`if rid != "unbound"`) run for real. async: false —
  mount reads the global `:meerkat` app env and the singleton
  `Meerkat.Decision`. The tests are split across files so each file's BEAM
  stays well under the per-file time limit.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Phoenix.LiveViewTest
  import Meerkat.TestHelpers, only: [make_git_repo: 1]

  alias MeerkatWeb.ReviewLive

  # `live_isolated/2` reads the calling module's endpoint.
  @endpoint MeerkatWeb.Endpoint

  # ConnCase applies `Meerkat.Case`'s isolation.
  defmacro __using__(_opts) do
    quote do
      use MeerkatWeb.ConnCase, async: false

      import Phoenix.LiveViewTest
      import MeerkatWeb.ReviewLiveEventsCase

      # After ConnCase's setup, so its global-state check runs after
      # this setup's on_exit restores the app env.
      setup :isolate_review_env
    end
  end

  def isolate_review_env(_context) do
    test_pid = self()

    prev =
      for key <- [:review_state, :review_id, :repo_path, :restart_fun, :settings_path] do
        {key, Application.fetch_env(:meerkat, key)}
      end

    Application.put_env(:meerkat, :restart_fun, fn code -> send(test_pid, {:restart, code}) end)
    # Each test starts from the default toolbar settings.
    settings_dir = Meerkat.TestHelpers.tmp_path("meerkat-lv-settings")
    Application.put_env(:meerkat, :settings_path, Path.join(settings_dir, "settings.json"))

    on_exit(fn ->
      Enum.each(prev, fn
        {key, {:ok, val}} -> Application.put_env(:meerkat, key, val)
        {key, :error} -> Application.delete_env(:meerkat, key)
      end)

      File.rm_rf!(settings_dir)
    end)

    :ok
  end

  def plain_file do
    %{
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
  end

  def md_file do
    %{
      status: :modified,
      file_name: "README.md",
      old_file_name: nil,
      old_content: "# Title\n\nOld paragraph.\n",
      new_content: "# Title\n\nNew paragraph.\n",
      hunks: ["@@ -1,3 +1,3 @@\n # Title\n \n-Old paragraph.\n+New paragraph."],
      additions: 1,
      deletions: 1,
      read_errors: [],
      effective_oid: "",
      is_generated: false,
      is_binary: false
    }
  end

  # Subject at L1, a two-line body at L3-4, list items at L6 and L7.
  def commit_msg do
    """
    Subject line under sixty-three chars

    Body paragraph that explains the why.
    Multiple lines so the gutter has a multi-line block.

    - bullet one
    - bullet two
    """
  end

  def tmp_git_repo do
    # Shared helper: its git calls strip the GIT_* discovery overrides a
    # git hook exports, which would otherwise point `git init` away from
    # dir and leave this fixture not-a-repo under the pre-push hook.
    make_git_repo("meerkat-lv")
  end

  def put_state(state) do
    Application.put_env(:meerkat, :review_state, state)
    Application.put_env(:meerkat, :review_id, "unbound")
  end

  def mount_unbound(conn, state \\ %Meerkat.ReviewState{files: [plain_file()]}) do
    put_state(state)
    {:ok, view, _html} = live_isolated(conn, ReviewLive)
    view
  end

  def mount_bound(conn, state, repo_path) do
    rid = "lvtest-#{System.unique_integer([:positive])}"
    Application.put_env(:meerkat, :review_id, rid)
    Application.put_env(:meerkat, :repo_path, repo_path)
    Application.put_env(:meerkat, :review_state, state)
    {:ok, view, _html} = live_isolated(conn, ReviewLive)
    {view, rid}
  end

  defdelegate commit(repo, message), to: Meerkat.TestHelpers

  def count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  # The props a LiveSvelte mount point hands its Svelte component, read
  # from `html`, the render that mounted it. Later renders carry only
  # the props that changed, so after a bound review's ReviewServer
  # broadcast re-renders the page, `data-props` is `{}`.
  def svelte_props(html, id) do
    [json] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query_by_id(id)
      |> LazyHTML.attribute("data-props")

    Jason.decode!(json)
  end

  # The event CommentForm.svelte pushes when the submit button of the
  # form keyed `form_key` is pressed.
  def submit_comment(view, form_key, body, finding_type \\ "issue") do
    render_hook(view, "comment.submit", %{
      "form_key" => form_key,
      "body" => body,
      "finding_type" => finding_type,
      "correct_instructions" => false,
      "lint_rule" => false
    })
  end

  # "+ Add global comment" or "+ Add another", whichever is showing.
  def add_global_comment(view, body, finding_type \\ "issue") do
    view |> element("button[phx-click='comment_form.show_global']") |> render_click()
    submit_comment(view, "global", body, finding_type)
  end

  # The DOM id of the form keyed `form_key`, as `ReviewLive` renders it.
  def form_id(form_key), do: "CommentForm-" <> String.replace(form_key, ~r/[^A-Za-z0-9_-]/, "-")

  def open_files_panel(view) do
    view |> element("button.toolbar-icon-btn", "Files") |> render_click()
  end

  # DiffViewer names it `ruler_columns`, CommentForm `rulerColumns`.
  def rulers_prop(props), do: props["ruler_columns"] || props["rulerColumns"]

  # The settings file's contents.
  def saved_settings, do: Jason.decode!(File.read!(Meerkat.Settings.path()))
end
