defmodule MeerkatWeb.ReviewLiveEventsTest do
  # Drives `MeerkatWeb.ReviewLive`'s event handlers hermetically:
  # unbound mode injects state via app env; bound mode starts a real
  # ReviewServer against a throwaway `git init` dir so the delegation
  # branches (`if rid != "unbound"`) run for real. These kill the
  # handler mutants muex found once this module's tests were visible
  # to its dependency analysis. async: false — mount reads the global
  # `:meerkat` app env and the singleton `Meerkat.Decision`.
  use MeerkatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Meerkat.{ApprovalCache, Decision, PendingAnswers, ReviewServer, ReviewState}
  alias MeerkatWeb.ReviewLive

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
    # Crypto-random suffix: System.unique_integer restarts per VM boot,
    # so two consecutive `mix test` runs could collide on the same dir
    # and inherit a stale repo (staged files, persistence snapshots).
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    dir = Path.join(System.tmp_dir!(), "meerkat-lv-\#{suffix}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    dir
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

    # Junk index: no-op — the previously-open form stays open, no crash.
    html = render_click(view, "comment_form.show_file", %{"file_index" => "junk"})
    assert html =~ "CommentForm-file-0"

    assert render_click(view, "comment_form.hide", %{}) =~ ""
    refute render(view) =~ "CommentForm-global"
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

    assert html =~ "CommentForm-commit-msg"

    html =
      render_hook(view, "comment_form.show_commit_msg", %{"start_line" => "x", "end_line" => "3"})

    assert html =~ "CommentForm-commit-msg"
  end

  test "comment.submit with no open form is a no-op; unbound submit just closes", %{conn: conn} do
    view = mount_unbound(conn)
    # open_form == nil clause: must not crash.
    render_click(view, "comment.submit", %{
      "body" => "x",
      "finding_type" => "issue",
      "learn_from_this" => false
    })

    render_hook(view, "comment_form.show_global", %{})

    render_click(view, "comment.submit", %{
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

  test "set_open_form persists to the ReviewServer in bound mode", %{conn: conn} do
    repo = tmp_git_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    render_hook(view, "comment_form.show_file", %{"file_index" => "0"})
    assert %{} = ReviewServer.get_state(rid).open_form

    render_hook(view, "comment_form.hide", %{})
    assert ReviewServer.get_state(rid).open_form == nil
  end

  ## --- Approvals ---

  test "toggle_approved in bound mode delegates and persists the cache", %{conn: conn} do
    repo = tmp_git_repo()
    File.write!(Path.join(repo, "src_widget.rs"), "content\n")
    {_, 0} = System.cmd("git", ["add", "src_widget.rs"], cd: repo)
    {oid, 0} = System.cmd("git", ["rev-parse", ":src_widget.rs"], cd: repo)
    oid = String.trim(oid)

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
    {_, 0} = System.cmd("git", ["add", "f.ex"], cd: repo)

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
    {_, 0} = System.cmd("git", ["add", "f.ex"], cd: repo)
    {oid, 0} = System.cmd("git", ["rev-parse", ":f.ex"], cd: repo)
    oid = String.trim(oid)

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
end
