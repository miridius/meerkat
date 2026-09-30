defmodule MeerkatWeb.ReviewLiveEventsTest do
  # Drives `MeerkatWeb.ReviewLive`'s event handlers hermetically:
  # unbound mode injects state via app env; bound mode starts a real
  # ReviewServer against a throwaway `git init` dir so the delegation
  # branches (`if rid != "unbound"`) run for real. These kill the
  # handler mutants muex found once this module's tests were visible
  # to its dependency analysis. async: false — mount reads the global
  # `:meerkat` app env and the singleton `Meerkat.Decision`.
  #
  # --- Documented surviving mutants (review-and-merge step 5) ---
  #
  # Equivalent (no input distinguishes mutant from original):
  # * `attr` declarations in function components `learn_toggle`,
  #   `version_chip`, `commit_message_section`, `global_comments_section`,
  #   `file_list`, `markdown_preview`, `file_filter`, and `diff_toolbar` —
  #   deleting an `attr` line removes compile-time validation metadata
  #   only; with every call site passing its assigns, no runtime behaviour
  #   differs. `markdown_preview`'s `:read_errors` attr default is never
  #   used because its only caller always passes `read_errors`.
  #
  # Thin I/O wiring already covered end-to-end by named Playwright
  # specs (muex runs ExUnit only and cannot see them):
  # * `mount/3`'s `if connected?(socket)` viewer-registration/PubSub
  #   subscribe — multi-tab.spec.ts "a global comment added in tab A
  #   appears in tab B without a reload" and "removing a comment in
  #   tab A removes it from tab B too".
  # * The whole `comment_form.edit` handler — comments.spec.ts "add a
  #   file comment via the per-file button, edit, remove" and "add a
  #   global comment, edit its body, remove it".
  # * `comment.submit`'s cond clauses
  #   for edit and add — comments.spec.ts "clicking the L1 gutter row
  #   opens a commit-msg form, comment lands in the gutter".
  # * The whole `filter.toggle_extension` handler, including its
  #   `if rid != "unbound"` — filter.spec.ts "hide *.md hides NOTES.md;
  #   chip click restores it".
  # * `filter.toggle_generated`'s handler and its
  #   `if rid != "unbound"` — filter.spec.ts generated-chip toggle and
  #   generated-files.spec.ts.
  # * `decision.cancel`'s ReviewServer wipe — decision.spec.ts "Cancel
  #   wipes comments, prints a cancelled sentence, exits 1".
  # * The whole `comment.toggle_learn` handler, including its
  #   `if rid != "unbound"` ReviewServer delegation —
  #   inline-comments-rendering.spec.ts "learn-from-this defaults off;
  #   toggle on rendered comment flips it".

  use MeerkatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Meerkat.{ApprovalCache, Decision, PendingAnswers, ReviewServer, ReviewState}
  alias MeerkatWeb.ReviewLive
  import Meerkat.TestHelpers, only: [make_git_repo: 1, git: 2]

  @plain_file %{
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

  @md_file %{
    status: :modified,
    file_name: "README.md",
    old_file_name: nil,
    old_content: "# Title\n\nOld paragraph.\n",
    new_content: "# Title\n\nNew paragraph.\n",
    hunks: ["@@ -1,3 +1,3 @@\n # Title\n \n-Old paragraph.\n+New paragraph."],
    read_errors: [],
    effective_oid: "",
    is_generated: false,
    is_binary: false
  }

  setup do
    Decision.reset()
    test_pid = self()

    prev =
      for key <- [:review_state, :review_id, :repo_path, :restart_fun] do
        {key, Application.fetch_env(:meerkat, key)}
      end

    Application.put_env(:meerkat, :restart_fun, fn code -> send(test_pid, {:restart, code}) end)

    on_exit(fn ->
      Decision.reset()

      Enum.each(prev, fn
        {key, {:ok, val}} -> Application.put_env(:meerkat, key, val)
        {key, :error} -> Application.delete_env(:meerkat, key)
      end)
    end)

    :ok
  end

  defp tmp_git_repo do
    # Shared helper: its git calls strip the GIT_* discovery overrides a
    # git hook exports, which would otherwise point `git init` away from
    # dir and leave this fixture not-a-repo under the pre-push hook.
    make_git_repo("meerkat-lv")
  end

  defp put_state(state) do
    Application.put_env(:meerkat, :review_state, state)
    Application.put_env(:meerkat, :review_id, "unbound")
  end

  defp mount_unbound(conn, state \\ %ReviewState{files: [@plain_file]}) do
    put_state(state)
    {:ok, view, _html} = live_isolated(conn, ReviewLive)
    view
  end

  defp mount_bound(conn, state, repo_path) do
    rid = "lvtest-#{System.unique_integer([:positive])}"
    Application.put_env(:meerkat, :review_id, rid)
    Application.put_env(:meerkat, :repo_path, repo_path)
    Application.put_env(:meerkat, :review_state, state)
    {:ok, view, _html} = live_isolated(conn, ReviewLive)
    {view, rid}
  end

  defp no_push_event(view, event) do
    pushed =
      try do
        assert_push_event(view, event, %{})
        true
      rescue
        ExUnit.AssertionError -> false
        ArgumentError -> false
      end

    refute pushed, "expected no #{event} push"
  end

  ## --- Toolbar ---

  test "toolbar.set_font_size accepts an integer and ignores junk", %{conn: conn} do
    view = mount_unbound(conn)

    html = render_click(view, "toolbar.set_font_size", %{"px" => "15"})
    assert html =~ "15px"

    html = render_click(view, "toolbar.set_font_size", %{"px" => "junk"})
    assert html =~ "15px"
  end

  test "toolbar.bump_font_size steps and clamps", %{conn: conn} do
    view = mount_unbound(conn)

    html = render_click(view, "toolbar.bump_font_size", %{"by" => "1"})
    assert html =~ "14px"

    # 28 is the ceiling: bumping past it pins at 28.
    html =
      view
      |> render_click("toolbar.set_font_size", %{"px" => "28"})
      |> then(fn _ -> render_click(view, "toolbar.bump_font_size", %{"by" => "1"}) end)

    assert html =~ "28px"
  end

  test "toolbar.set_tab_size accepts 2/4/8 and ignores junk", %{conn: conn} do
    view = mount_unbound(conn)

    assert render_click(view, "toolbar.set_tab_size", %{"n" => "8"}) =~ "8"
    assert render_click(view, "toolbar.set_tab_size", %{"n" => "3"}) =~ "8"
  end

  test "set_diff_mode flips the active segment", %{conn: conn} do
    view = mount_unbound(conn)
    html = render_click(view, "set_diff_mode", %{"mode" => "unified"})
    assert html =~ "active"
  end

  ## --- Decision ---

  test "approve renders the Approved done view and clears pending answers", %{conn: conn} do
    repo = tmp_git_repo()

    {:ok, _} =
      PendingAnswers.save(
        repo,
        ~s({"answers":[{"location":"f.ex:1","question":"q","answer":"a"}]})
      )

    assert PendingAnswers.load(repo)

    put_state(%ReviewState{files: [%{@plain_file | effective_oid: nil}]})
    Application.put_env(:meerkat, :repo_path, repo)
    {:ok, view, _html} = live_isolated(conn, ReviewLive)

    html = render_click(view, "decision.approve", %{})
    assert html =~ "Approved"

    # Pending answers were cleared out of THIS repo, not the cwd's.
    refute PendingAnswers.load(repo)

    # Unbound review: no drafts:wipe push (there is no review id to wipe).
    no_push_event(view, "drafts:wipe")
  end

  test "approve in bound mode wipes drafts and mirrors the approval cache", %{conn: conn} do
    repo = tmp_git_repo()

    state = %ReviewState{
      files: [%{@plain_file | effective_oid: "oid1", file_name: "src/widget.rs"}],
      head_branch: "main"
    }

    {view, _rid} = mount_bound(conn, state, repo)

    html = render_click(view, "decision.approve", %{})
    assert html =~ "Approved"
    assert_push_event(view, "drafts:wipe", %{})

    cache = ApprovalCache.load_for(repo)
    assert ApprovalCache.approved?(cache, "main", "src/widget.rs", "oid1")
  end

  test "approve picks approve_with_feedback when comments exist", %{conn: conn} do
    state = %ReviewState{
      files: [%{@plain_file | effective_oid: nil}],
      global_comments: [%{id: "g1", body: "note", finding_type: :issue, learn_from_this: false}]
    }

    put_state(state)
    {:ok, view, _html} = live_isolated(conn, ReviewLive)

    html = render_click(view, "decision.approve", %{})
    assert html =~ "Approved"

    decision = Decision.current()
    assert elem(decision, 0) == :approve_with_feedback
  end

  test "reject renders the Feedback-sent done view", %{conn: conn} do
    view = mount_unbound(conn)
    html = render_click(view, "decision.reject", %{})
    assert html =~ "Feedback sent"
  end

  test "post_to_github without an attached PR flashes and dismisses", %{conn: conn} do
    view = mount_unbound(conn, %ReviewState{files: [@plain_file], pr: nil})

    html = render_click(view, "decision.post_to_github", %{})
    assert html =~ "No PR attached to this review"

    html = render_click(view, "flash.dismiss", %{})
    refute html =~ "No PR attached to this review"
  end

  test "post_to_github flashes when gh cannot run", %{conn: conn} do
    repo = tmp_git_repo()

    state = %ReviewState{
      files: [%{@plain_file | effective_oid: nil}],
      pr: %{number: 7, title: "t", url: "u"}
    }

    {view, _rid} = mount_bound(conn, state, repo)

    # No gh on PATH → the post fails → the operator sees the flash.
    prev_path = System.get_env("PATH")
    System.put_env("PATH", "/nonexistent")

    try do
      html = render_click(view, "decision.post_to_github", %{})
      assert html =~ "Couldn&#39;t post review to GitHub"
    after
      case prev_path do
        nil -> System.delete_env("PATH")
        p -> System.put_env("PATH", p)
      end
    end
  end

  ## --- Forms ---

  test "form open/close on every surface (unbound)", %{conn: conn} do
    view = mount_unbound(conn)

    assert render_click(view, "comment_form.show_global", %{}) =~ "CommentForm-global"

    html = render_click(view, "comment_form.show_file", %{"file_index" => "0"})
    assert html =~ "CommentForm-file-0"

    # Opening a second form keeps the first open.
    assert html =~ "CommentForm-global"

    # Junk index: no-op — the previously-open form stays open, no crash.
    html = render_click(view, "comment_form.show_file", %{"file_index" => "junk"})
    assert html =~ "CommentForm-file-0"

    # Hiding one form by key leaves the other open.
    html = render_click(view, "comment_form.hide", %{"form_key" => "global"})
    refute html =~ "CommentForm-global"
    assert html =~ "CommentForm-file-0"
  end

  test "inline forms at different lines stay open together; each submit posts at its own lines",
       %{conn: conn} do
    repo = tmp_git_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    for {from, to} <- [{"1", "1"}, {"2", "3"}] do
      render_hook(view, "comment_form.show_at_line", %{
        "file_index" => "0",
        "start_line" => from,
        "end_line" => to,
        "side" => "new"
      })
    end

    assert [%{anchor: %{start_line: 1}}, %{anchor: %{start_line: 2}}] =
             ReviewServer.get_state(rid).open_forms

    render_hook(view, "comment.submit", %{
      "form_key" => "inline:0:new:1-1",
      "body" => "first",
      "finding_type" => "issue",
      "learn_from_this" => false
    })

    state = ReviewServer.get_state(rid)
    assert [%{body: "first", start_line: 1, end_line: 1}] = state.comments
    assert [%{anchor: %{start_line: 2, end_line: 3}}] = state.open_forms
  end

  test "commit-msg gutter form opens for block ranges", %{conn: conn} do
    state = %ReviewState{
      files: [@plain_file],
      commit_message: "subject",
      commit_message_blocks: [%{start_line: 1, end_line: 3, text: "subject"}]
    }

    view = mount_unbound(conn, state)

    html =
      render_hook(view, "comment_form.show_commit_msg", %{"start_line" => "1", "end_line" => "3"})

    assert html =~ "CommentForm-commit_msg-1-3"

    html =
      render_hook(view, "comment_form.show_commit_msg", %{"start_line" => "x", "end_line" => "3"})

    assert html =~ "CommentForm-commit_msg-1-3"
  end

  test "commit-msg forms at two ranges are labelled and each posts at its own range",
       %{conn: conn} do
    repo = tmp_git_repo()

    state = %ReviewState{
      files: [@plain_file],
      commit_message: "subject\n\nbody\nmore",
      commit_message_blocks: [
        %{start_line: 1, end_line: 1, text: "subject"},
        %{start_line: 3, end_line: 4, text: "body\nmore"}
      ]
    }

    {view, rid} = mount_bound(conn, state, repo)

    render_hook(view, "comment_form.show_commit_msg", %{"start_line" => "1", "end_line" => "1"})

    html =
      render_hook(view, "comment_form.show_commit_msg", %{"start_line" => "3", "end_line" => "4"})

    assert html =~ "CommentForm-commit_msg-1-1"
    assert html =~ "CommentForm-commit_msg-3-4"

    labels =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".commit-msg-form .line-anchor")
      |> Enum.map(&LazyHTML.text/1)

    assert labels == ["L1–1", "L3–4"]

    render_hook(view, "comment.submit", %{
      "form_key" => "commit_msg:3-4",
      "body" => "second range",
      "finding_type" => "issue",
      "learn_from_this" => false
    })

    state = ReviewServer.get_state(rid)
    assert [%{body: "second range", start_line: 3, end_line: 4}] = state.commit_message_comments
    assert [%{surface: :commit_msg, anchor: %{start_line: 1, end_line: 1}}] = state.open_forms
  end

  test "the footer names every open form, as a link that reveals it", %{conn: conn} do
    state = %ReviewState{
      files: [@plain_file],
      commit_message: "subject",
      commit_message_blocks: [%{start_line: 1, end_line: 3, text: "subject"}]
    }

    view = mount_unbound(conn, state)
    refute has_element?(view, ".dirty-marker")

    render_hook(view, "comment_form.show_global", %{})
    assert has_element?(view, ".dirty-marker", "1 unsaved form open:")

    render_hook(view, "comment_form.show_commit_msg", %{"start_line" => "1", "end_line" => "3"})
    render_hook(view, "comment_form.show_file", %{"file_index" => "0"})
    render_hook(view, "comment_form.show_file", %{"file_index" => "7"})

    for {from, to, side} <- [{"2", "2", "new"}, {"2", "4", "old"}] do
      render_hook(view, "comment_form.show_at_line", %{
        "file_index" => "0",
        "start_line" => from,
        "end_line" => to,
        "side" => side
      })
    end

    labels =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".dirty-marker .dirty-form-link")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert labels == [
             "Global",
             "Commit message L1–3",
             "src/widget.rs",
             "file 7",
             "src/widget.rs L2",
             "src/widget.rs L2–4 (old)"
           ]

    assert has_element?(view, ".dirty-marker", "6 unsaved forms open:")

    assert has_element?(
             view,
             ~s(.dirty-form-link[phx-click="comment_form.reveal"][phx-value-form_key="inline:0:old:2-4"])
           )
  end

  test "an edit form's footer link says it is editing", %{conn: conn} do
    comment = %{id: "g1", body: "b", finding_type: :issue, learn_from_this: false}
    view = mount_unbound(conn, %ReviewState{files: [@plain_file], global_comments: [comment]})

    render_click(view, "comment_form.edit", %{"surface" => "global", "id" => "g1"})
    assert has_element?(view, ".dirty-form-link", "Global (editing)")
  end

  test "revealing a form in a filtered-out, collapsed file shows and expands it", %{conn: conn} do
    repo = tmp_git_repo()
    other = %{@plain_file | file_name: "other.ex"}

    state = %ReviewState{
      files: [@plain_file, other],
      approved_file_names: MapSet.new(["src/widget.rs"])
    }

    {view, rid} = mount_bound(conn, state, repo)

    render_hook(view, "comment_form.show_at_line", %{
      "file_index" => "0",
      "start_line" => "1",
      "end_line" => "1",
      "side" => "new"
    })

    render_hook(view, "filter.set_input", %{"value" => "other"})
    render_click(view, "filter.show_only", %{"file_index" => "1"})
    refute has_element?(view, "#file-0")

    render_click(view, "comment_form.reveal", %{"form_key" => "inline:0:new:1-1"})

    assert has_element?(view, "#file-0")
    refute has_element?(view, "#file-0.collapsed")
    # Show-only and the substring filter are cleared: both files show.
    assert has_element?(view, "#file-1")
    assert ReviewServer.get_state(rid).file_overrides == %{"src/widget.rs" => :show}

    assert_push_event(view, "comment-form:reveal", %{
      key: "inline:0:new:1-1",
      id: "CommentForm-inline-0-new-1-1"
    })
  end

  test "revealing keeps a filter that already shows the file", %{conn: conn} do
    other = %{@plain_file | file_name: "other.ex"}
    view = mount_unbound(conn, %ReviewState{files: [@plain_file, other]})

    render_hook(view, "comment_form.show_file", %{"file_index" => "0"})
    render_hook(view, "filter.set_input", %{"value" => "widget"})
    render_click(view, "comment_form.reveal", %{"form_key" => "file:0"})

    assert has_element?(view, "#file-0")
    refute has_element?(view, "#file-1")
    assert_push_event(view, "comment-form:reveal", %{key: "file:0", id: "CommentForm-file-0"})
  end

  test "revealing a file form expands a file collapsed by hand, keeping it rendered",
       %{conn: conn} do
    view = mount_unbound(conn, %ReviewState{files: [@md_file]})

    render_click(view, "file.toggle_rendered", %{"file_name" => "README.md"})
    render_click(view, "file.toggle_expanded", %{"file_name" => "README.md"})
    render_hook(view, "comment_form.show_file", %{"file_index" => "0"})
    assert has_element?(view, "#file-0.collapsed")

    render_click(view, "comment_form.reveal", %{"form_key" => "file:0"})
    refute has_element?(view, "#file-0.collapsed")
    # A file comment doesn't need the diff, so the rendered view stays.
    assert has_element?(view, "#file-0 .md-preview")
  end

  test "revealing an inline form switches a rendered markdown file back to its diff",
       %{conn: conn} do
    view = mount_unbound(conn, %ReviewState{files: [@md_file]})

    render_hook(view, "comment_form.show_at_line", %{
      "file_index" => "0",
      "start_line" => "3",
      "end_line" => "3",
      "side" => "new"
    })

    render_click(view, "file.toggle_rendered", %{"file_name" => "README.md"})
    assert has_element?(view, "#file-0 .md-preview")

    render_click(view, "comment_form.reveal", %{"form_key" => "inline:0:new:3-3"})
    refute has_element?(view, "#file-0 .md-preview")
  end

  test "revealing a global form only scrolls; an unknown key does nothing", %{conn: conn} do
    view = mount_unbound(conn)

    render_click(view, "comment_form.reveal", %{"form_key" => "global"})
    no_push_event(view, "comment-form:reveal")

    render_hook(view, "comment_form.show_global", %{})
    render_click(view, "comment_form.reveal", %{"form_key" => "global"})
    assert_push_event(view, "comment-form:reveal", %{key: "global", id: "CommentForm-global"})

    # A file form whose index the diff doesn't have: no file to show.
    render_hook(view, "comment_form.show_file", %{"file_index" => "7"})
    render_click(view, "comment_form.reveal", %{"form_key" => "file:7"})
    assert_push_event(view, "comment-form:reveal", %{key: "file:7"})
  end

  test "comment_form.hide without a form_key is ignored, not a crash", %{conn: conn} do
    view = mount_unbound(conn)
    render_click(view, "comment_form.show_global", %{})

    assert render_hook(view, "comment_form.hide", %{}) =~ "CommentForm-global"
  end

  test "comment.submit with no open form replies with an error; unbound submit just closes",
       %{conn: conn} do
    view = mount_unbound(conn)
    # No form open under that key: must not crash, and must tell the
    # form so it keeps its draft.
    render_click(view, "comment.submit", %{
      "form_key" => "global",
      "body" => "x",
      "finding_type" => "issue",
      "learn_from_this" => false
    })

    assert_reply(view, %{status: "error", message: "This comment form is no longer open" <> _})

    render_hook(view, "comment_form.show_global", %{})

    render_click(view, "comment.submit", %{
      "form_key" => "global",
      "body" => "x",
      "finding_type" => "issue",
      "learn_from_this" => false
    })

    refute render(view) =~ "CommentForm-global"
  end

  test "comment.remove delegates to the ReviewServer in bound mode", %{conn: conn} do
    repo = tmp_git_repo()

    comment = %{id: "f1", body: "b", finding_type: :issue, learn_from_this: false, file_index: 0}

    {view, rid} =
      mount_bound(conn, %ReviewState{files: [@plain_file], file_comments: [comment]}, repo)

    render_click(view, "comment.remove", %{"surface" => "file", "id" => "f1"})
    assert ReviewServer.get_state(rid).file_comments == []
  end

  test "opening and hiding forms persists to the ReviewServer in bound mode", %{conn: conn} do
    repo = tmp_git_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    render_hook(view, "comment_form.show_file", %{"file_index" => "0"})
    assert [%{surface: :file}] = ReviewServer.get_state(rid).open_forms

    render_hook(view, "comment_form.hide", %{"form_key" => "file:0"})
    assert ReviewServer.get_state(rid).open_forms == []
  end

  ## --- Approvals ---

  test "toggle_approved in bound mode delegates and persists the cache", %{conn: conn} do
    repo = tmp_git_repo()
    File.write!(Path.join(repo, "src_widget.rs"), "content\n")
    git(repo, ["add", "src_widget.rs"])
    oid = git(repo, ["rev-parse", ":src_widget.rs"])

    state = %ReviewState{
      files: [%{@plain_file | file_name: "src_widget.rs", effective_oid: oid}],
      head_branch: "main"
    }

    {view, rid} = mount_bound(conn, state, repo)

    html = render_hook(view, "file.toggle_approved", %{"file_name" => "src_widget.rs"})
    refute html =~ "didn&#39;t persist"
    assert ReviewServer.get_state(rid).approved_file_names == MapSet.new(["src_widget.rs"])
    assert ApprovalCache.approved?(ApprovalCache.load_for(repo), "main", "src_widget.rs", oid)

    # Un-tick: cache entry removed.
    render_hook(view, "file.toggle_approved", %{"file_name" => "src_widget.rs"})
    assert ReviewServer.get_state(rid).approved_file_names == MapSet.new()
    refute ApprovalCache.approved?(ApprovalCache.load_for(repo), "main", "src_widget.rs", oid)
  end

  test "approving a file with no effective_oid flashes instead of silently not persisting", %{
    conn: conn
  } do
    repo = tmp_git_repo()
    Application.put_env(:meerkat, :repo_path, repo)

    view =
      mount_unbound(conn, %ReviewState{
        files: [%{@plain_file | effective_oid: nil}],
        head_branch: "main"
      })

    html = render_hook(view, "file.toggle_approved", %{"file_name" => "src/widget.rs"})
    assert html =~ "didn&#39;t persist"
  end

  test "approving outside a git repo skips persistence without flashing", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "meerkat-lv-nogit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    put_state(%ReviewState{files: [%{@plain_file | effective_oid: nil}]})
    Application.put_env(:meerkat, :repo_path, dir)
    {:ok, view, _html} = live_isolated(conn, ReviewLive)

    html = render_hook(view, "file.toggle_approved", %{"file_name" => "src/widget.rs"})
    refute html =~ "didn&#39;t persist"
  end

  test "approving an oid whose live value changed flashes the stale warning", %{conn: conn} do
    repo = tmp_git_repo()
    File.write!(Path.join(repo, "f.ex"), "content\n")
    git(repo, ["add", "f.ex"])

    state = %ReviewState{
      files: [%{@plain_file | file_name: "f.ex", effective_oid: "deadbeef"}],
      head_branch: "main"
    }

    put_state(state)
    Application.put_env(:meerkat, :repo_path, repo)
    {:ok, view, _html} = live_isolated(conn, ReviewLive)

    html = render_hook(view, "file.toggle_approved", %{"file_name" => "f.ex"})
    assert html =~ "changed since you opened the review"
  end

  test "approving with the live oid matches proceeds without a flash", %{conn: conn} do
    repo = tmp_git_repo()
    File.write!(Path.join(repo, "f.ex"), "content\n")
    git(repo, ["add", "f.ex"])
    oid = git(repo, ["rev-parse", ":f.ex"])

    state = %ReviewState{
      files: [%{@plain_file | file_name: "f.ex", effective_oid: oid}],
      head_branch: "main"
    }

    put_state(state)
    Application.put_env(:meerkat, :repo_path, repo)
    {:ok, view, _html} = live_isolated(conn, ReviewLive)

    html = render_hook(view, "file.toggle_approved", %{"file_name" => "f.ex"})
    refute html =~ "didn&#39;t persist"
    refute html =~ "changed since"
  end

  ## --- Filter ---

  test "filter.set_input narrows the file list; non-map payload resets it", %{conn: conn} do
    state = %ReviewState{files: [@plain_file, %{@plain_file | file_name: "other.ex"}]}
    view = mount_unbound(conn, state)

    html = render_hook(view, "filter.set_input", %{"value" => "widget"})
    assert html =~ "src/widget.rs"
    refute html =~ "other.ex"

    # A map without the "value" key falls through to empty (everything visible).
    html = render_hook(view, "filter.set_input", %{})
    assert html =~ "other.ex"
  end

  test "filter.show_only / show_all (unbound)", %{conn: conn} do
    state = %ReviewState{files: [@plain_file, %{@plain_file | file_name: "other.ex"}]}
    view = mount_unbound(conn, state)

    html = render_hook(view, "filter.show_only", %{"file_index" => "1"})
    refute html =~ "src/widget.rs"
    assert html =~ "other.ex"

    html = render_click(view, "filter.show_all", %{})
    assert html =~ "src/widget.rs"
  end

  test "filter.show_all clears server-side overrides in bound mode", %{conn: conn} do
    repo = tmp_git_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    render_hook(view, "filter.show_only", %{"file_index" => "0"})
    render_click(view, "filter.show_all", %{})
    assert ReviewServer.get_state(rid).file_overrides == %{}
  end

  test "filter.toggle_file writes :hide for a visible file and :show for a hidden one", %{
    conn: conn
  } do
    repo = tmp_git_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    render_hook(view, "filter.toggle_file", %{"file_name" => "src/widget.rs"})
    assert ReviewServer.get_state(rid).file_overrides == %{"src/widget.rs" => :hide}

    render_hook(view, "filter.toggle_file", %{"file_name" => "src/widget.rs"})
    assert ReviewServer.get_state(rid).file_overrides == %{"src/widget.rs" => :show}
  end

  test "filter.toggle_file ignores unknown file names", %{conn: conn} do
    repo = tmp_git_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    render_hook(view, "filter.toggle_file", %{"file_name" => "nope.ex"})
    assert ReviewServer.get_state(rid).file_overrides == %{}
  end

  test "filter.hide_matched / show_matched scope to the substring filter", %{conn: conn} do
    repo = tmp_git_repo()

    state = %ReviewState{files: [@plain_file, %{@plain_file | file_name: "other.ex"}]}

    {view, rid} = mount_bound(conn, state, repo)

    render_hook(view, "filter.set_input", %{"value" => "widget"})
    render_click(view, "filter.hide_matched", %{})
    assert ReviewServer.get_state(rid).file_overrides == %{"src/widget.rs" => :hide}

    render_click(view, "filter.show_matched", %{})
    assert ReviewServer.get_state(rid).file_overrides == %{"src/widget.rs" => :show}
  end

  test "toolbar.toggle_files_panel opens the sidebar with a scroll nudge and closes it", %{
    conn: conn
  } do
    view = mount_unbound(conn)

    html = render_click(view, "toolbar.toggle_files_panel", %{})
    assert html =~ "file-filter"
    assert_push_event(view, "scroll-into-view", %{})

    # Closing does not nudge the scroll.
    html = render_click(view, "toolbar.toggle_files_panel", %{})
    refute html =~ "file-filter"
    no_push_event(view, "scroll-into-view")
  end

  test "file.toggle_expanded flips the collapse set for approved and unapproved files", %{
    conn: conn
  } do
    state = %ReviewState{
      files: [@plain_file],
      approved_file_names: MapSet.new(["src/widget.rs"])
    }

    view = mount_unbound(conn, state)

    # Approved → collapsed by default; the caret expands it.
    assert render(view) =~ "collapsed"
    html = render_click(view, "file.toggle_expanded", %{"file_name" => "src/widget.rs"})
    refute html =~ "collapsed"

    # Unapproved → expanded by default; the caret collapses it.
    html = render_click(view, "file.toggle_approved", %{"file_name" => "src/widget.rs"})
    html = render_click(view, "file.toggle_expanded", %{"file_name" => "src/widget.rs"})
    assert html =~ "collapsed"
  end

  test "file.toggle_rendered caches markdown sides in order; unknown and binary files no-op", %{
    conn: conn
  } do
    binary_file = %{
      @md_file
      | file_name: "logo.md",
        is_binary: true,
        old_content: nil,
        new_content: nil
    }

    state = %ReviewState{files: [@md_file, binary_file]}
    view = mount_unbound(conn, state)

    render_click(view, "file.toggle_rendered", %{"file_name" => "README.md"})
    assert has_element?(view, "#file-0 .md-preview")
    html = render(view)

    # Old pane before new pane, each with its own content — kills the
    # render_diff_sides argument-swap mutant.
    old_at = html |> String.split("Old paragraph.") |> hd() |> String.length()
    new_at = html |> String.split("New paragraph.") |> hd() |> String.length()
    assert old_at < new_at

    # Unknown file: no-op, no crash.
    render_click(view, "file.toggle_rendered", %{"file_name" => "nope.md"})

    # Binary file: no-op (no content to render) — its own section has
    # no preview while file 0's stays rendered.
    render_click(view, "file.toggle_rendered", %{"file_name" => "logo.md"})
    assert has_element?(view, "#file-0 .md-preview")
    refute has_element?(view, "#file-1 .md-preview")
  end

  test "hint.dismiss pushes the dismissed event", %{conn: conn} do
    view = mount_unbound(conn)
    render_click(view, "hint.dismiss", %{})
    assert_push_event(view, "hint:set-dismissed", %{})
  end

  test "post_to_github failure with gh missing pushes no url", %{conn: conn} do
    repo = tmp_git_repo()
    state = %ReviewState{files: [@plain_file], pr: %{number: 7, title: "t", url: "u"}}
    {view, _rid} = mount_bound(conn, state, repo)

    prev_path = System.get_env("PATH")
    System.put_env("PATH", "/nonexistent")

    try do
      render_click(view, "decision.post_to_github", %{})
    after
      case prev_path do
        nil -> System.delete_env("PATH")
        p -> System.put_env("PATH", p)
      end
    end

    no_push_event(view, "open-url")
  end

  # --- Third-pass kills (final survivors) ---

  test "approving a file that is no longer staged flashes the stale warning", %{conn: conn} do
    repo = tmp_git_repo()
    # The file exists but was never staged — the staged-blob lookup
    # reports :not_staged.
    File.write!(Path.join(repo, "f.ex"), "content\n")

    state = %ReviewState{
      files: [%{@plain_file | file_name: "f.ex", effective_oid: "deadbeef"}],
      head_branch: "main"
    }

    put_state(state)
    Application.put_env(:meerkat, :repo_path, repo)
    {:ok, view, _html} = live_isolated(conn, ReviewLive)

    html = render_hook(view, "file.toggle_approved", %{"file_name" => "f.ex"})
    assert html =~ "no longer staged"
  end

  test "un-approving does not push the scroll nudge; approving does", %{conn: conn} do
    repo = tmp_git_repo()

    state = %ReviewState{
      files: [%{@plain_file | effective_oid: nil}],
      head_branch: "main"
    }

    put_state(state)
    Application.put_env(:meerkat, :repo_path, repo)
    {:ok, view, _html} = live_isolated(conn, ReviewLive)

    render_hook(view, "file.toggle_approved", %{"file_name" => "src/widget.rs"})
    assert_push_event(view, "scroll-into-view", %{})

    # Fresh socket pre-approved: un-approving must not nudge the scroll.
    # A separate mount keeps the push mailbox clean for the negative
    # assertion.
    approved_state = %ReviewState{
      files: [%{@plain_file | effective_oid: nil}],
      head_branch: "main",
      approved_file_names: MapSet.new(["src/widget.rs"])
    }

    put_state(approved_state)
    {:ok, view2, _html} = live_isolated(conn, ReviewLive)

    render_hook(view2, "file.toggle_approved", %{"file_name" => "src/widget.rs"})
    no_push_event(view2, "scroll-into-view")
  end

  test "a second decision submit still lands on the done view", %{conn: conn} do
    put_state(%ReviewState{files: [%{@plain_file | effective_oid: nil}]})
    {:ok, view, _html} = live_isolated(conn, ReviewLive)

    render_click(view, "decision.approve", %{})
    assert render(view) =~ "Approved"

    # Already-decided submit returns {:already_decided, _} — the done
    # view must not regress to the live review.
    html = render_click(view, "decision.approve", %{})
    assert html =~ "Approved"
    assert html =~ "You can close this tab"
  end

  test "approve's bulk cache write skips files without an effective oid", %{conn: conn} do
    repo = tmp_git_repo()

    state = %ReviewState{
      files: [
        %{@plain_file | file_name: "staged.ex", effective_oid: "oid1"},
        %{@plain_file | file_name: "blank.ex", effective_oid: ""}
      ],
      head_branch: "main"
    }

    {view, _rid} = mount_bound(conn, state, repo)

    render_click(view, "decision.approve", %{})
    cache = ApprovalCache.load_for(repo)
    assert ApprovalCache.approved?(cache, "main", "staged.ex", "oid1")
    # A blank oid would content-address nothing — it must not be cached.
    refute ApprovalCache.approved?(cache, "main", "blank.ex", "")
    refute Map.has_key?(cache["main"] || %{}, "blank.ex")
  end
end
