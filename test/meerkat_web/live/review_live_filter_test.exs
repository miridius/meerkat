defmodule MeerkatWeb.ReviewLiveFilterTest do
  # Drives `MeerkatWeb.ReviewLive`'s approval and file-filter event
  # handlers; `MeerkatWeb.ReviewLiveEventsCase` describes the setup.

  use MeerkatWeb.ReviewLiveEventsCase

  alias Meerkat.{ApprovalCache, Decision, ReviewServer, ReviewState}
  alias MeerkatWeb.ReviewLive
  import Meerkat.TestHelpers, only: [git: 2, stage: 3]

  @plain_file plain_file()
  @md_file md_file()

  ## --- Approvals ---

  test "toggle_approved in bound mode delegates and persists the cache", %{conn: conn} do
    repo = tmp_git_repo()
    File.write!(Path.join(repo, "src_widget.rs"), "content\n")
    git(repo, ["add", "src_widget.rs"])
    oid = git(repo, ["rev-parse", ":src_widget.rs"])

    state = %ReviewState{
      files: [%{@plain_file | file_name: "src_widget.rs", effective_oid: oid}],
      head_branch: "main",
      precommit?: true
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

  test "an approved staged deletion stays approved in the next review round", %{conn: conn} do
    repo = tmp_git_repo()
    stage(repo, "gone.rs", "fn gone() {}\n")
    stage(repo, "keep.rs", "fn keep() -> i32 { 1 }\n")
    commit(repo, "seed")
    git(repo, ["rm", "-q", "gone.rs"])
    stage(repo, "keep.rs", "fn keep() -> i32 { 2 }\n")

    {:ok, round1} = ReviewState.from_target({:staged, nil}, repo)
    assert round1.approved_file_names == MapSet.new()
    {view, _rid} = mount_bound(conn, round1, repo)

    view
    |> element(".approved-toggle input[phx-value-file_name='gone.rs']")
    |> render_click()

    # The deletion is untouched while keep.rs is reworked; round 2
    # re-hydrates approvals from the content-addressed cache.
    stage(repo, "keep.rs", "fn keep() -> i32 { 3 }\n")
    {:ok, round2} = ReviewState.from_target({:staged, nil}, repo)
    assert round2.approved_file_names == MapSet.new(["gone.rs"])

    {view, _rid} = mount_bound(conn, round2, repo)
    assert has_element?(view, ".approved-toggle input[phx-value-file_name='gone.rs'][checked]")
    refute has_element?(view, ".approved-toggle input[phx-value-file_name='keep.rs'][checked]")
  end

  test "approving a file with no effective_oid flashes instead of silently not persisting", %{
    conn: conn
  } do
    repo = tmp_git_repo()
    Application.put_env(:meerkat, :repo_path, repo)

    view =
      mount_unbound(conn, %ReviewState{
        files: [%{@plain_file | effective_oid: nil}],
        head_branch: "main",
        precommit?: true
      })

    html = render_hook(view, "file.toggle_approved", %{"file_name" => "src/widget.rs"})
    assert html =~ "didn&#39;t persist"
  end

  test "ticking Approved in a PR / range review leaves the approval cache alone", %{conn: conn} do
    repo = tmp_git_repo()

    # A staged-mode approval already cached for the same branch name.
    ApprovalCache.modify(ApprovalCache.path_for(repo), fn cache ->
      ApprovalCache.approve(cache, "feature", "src/widget.rs", "staged-oid")
    end)

    state = %ReviewState{files: [%{@plain_file | effective_oid: nil}], head_branch: "feature"}
    {view, rid} = mount_bound(conn, state, repo)

    html = render_hook(view, "file.toggle_approved", %{"file_name" => "src/widget.rs"})
    refute html =~ "didn&#39;t persist"
    assert ReviewServer.get_state(rid).approved_file_names == MapSet.new(["src/widget.rs"])

    # Un-tick: bound mode makes this a real unapprove, which must not
    # drop the staged approval cached under the same branch name.
    render_hook(view, "file.toggle_approved", %{"file_name" => "src/widget.rs"})
    assert ReviewServer.get_state(rid).approved_file_names == MapSet.new()

    assert ApprovalCache.approved?(
             ApprovalCache.load_for(repo),
             "feature",
             "src/widget.rs",
             "staged-oid"
           )
  end

  test "approving outside a git repo skips persistence without flashing", %{conn: conn} do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-lv-nogit")
    File.mkdir_p!(dir)

    put_state(%ReviewState{files: [%{@plain_file | effective_oid: nil}], precommit?: true})
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
      head_branch: "main",
      precommit?: true
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
    open_files_panel(view)
    assert has_element?(view, ".file-filter-toggle", "Files (2 of 2)")

    view |> element(".file-filter form") |> render_change(%{"value" => "widget"})
    assert has_element?(view, ".file-filter .base-name", "widget.rs")
    refute has_element?(view, ".file-filter .base-name", "other.ex")
    assert has_element?(view, ".file-filter-toggle", "Files (1 of 2)")
    assert has_element?(view, ".file-list .file-name", "src/widget.rs")
    refute has_element?(view, ".file-list .file-name", "other.ex")

    # A map without the "value" key falls through to empty (everything visible).
    render_hook(view, "filter.set_input", %{})
    assert has_element?(view, ".file-list .file-name", "other.ex")
  end

  test "filter.show_only / show_all (unbound)", %{conn: conn} do
    state = %ReviewState{files: [@plain_file, %{@plain_file | file_name: "other.ex"}]}
    view = mount_unbound(conn, state)
    open_files_panel(view)
    refute has_element?(view, ".file-filter button", "Show all")

    view |> element(".file-filter .only-btn[phx-value-file_index='1']") |> render_click()
    refute has_element?(view, ".file-list .file-name", "src/widget.rs")
    assert has_element?(view, ".file-list .file-name", "other.ex")
    assert has_element?(view, ".file-filter-toggle", "Files (1 of 2)")

    view |> element(".file-filter button", "Show all") |> render_click()
    assert has_element?(view, ".file-list .file-name", "src/widget.rs")
    refute has_element?(view, ".file-filter button", "Show all")
  end

  test "the file panel count follows generated files, hidden extensions and overrides",
       %{conn: conn} do
    state = %ReviewState{
      files: [
        @plain_file,
        %{@plain_file | file_name: "notes.md"},
        %{@plain_file | file_name: "gen.lock", is_generated: true}
      ],
      hidden_extensions: MapSet.new(["md"])
    }

    view = mount_unbound(conn, state)
    open_files_panel(view)
    assert has_element?(view, ".file-filter-toggle", "Files (1 of 3)")

    view = mount_unbound(conn, %{state | file_overrides: %{"gen.lock" => :show}})
    open_files_panel(view)
    assert has_element?(view, ".file-filter-toggle", "Files (2 of 3)")
  end

  test "filter.show_only keeps the filter string, so both must match", %{conn: conn} do
    state = %ReviewState{files: [@plain_file, %{@plain_file | file_name: "other.ex"}]}
    view = mount_unbound(conn, state)

    render_hook(view, "filter.set_input", %{"value" => "widget"})
    render_hook(view, "filter.show_only", %{"file_index" => "1"})

    refute has_element?(view, "#file-0")
    refute has_element?(view, "#file-1")
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

  test "filter.toggle_file shows a file that show-only hides", %{conn: conn} do
    repo = tmp_git_repo()
    state = %ReviewState{files: [@plain_file, %{@plain_file | file_name: "other.ex"}]}
    {view, _rid} = mount_bound(conn, state, repo)

    render_hook(view, "filter.show_only", %{"file_index" => "1"})
    refute has_element?(view, ".file-list .file-name", "src/widget.rs")

    render_hook(view, "filter.toggle_file", %{"file_name" => "src/widget.rs"})
    assert has_element?(view, ".file-list .file-name", "src/widget.rs")
    assert has_element?(view, ".file-list .file-name", "other.ex")
  end

  test "filter.toggle_file re-showing the show-only file keeps show-only", %{conn: conn} do
    repo = tmp_git_repo()
    state = %ReviewState{files: [@plain_file, %{@plain_file | file_name: "other.ex"}]}
    {view, _rid} = mount_bound(conn, state, repo)

    render_hook(view, "filter.show_only", %{"file_index" => "0"})
    render_hook(view, "filter.toggle_file", %{"file_name" => "src/widget.rs"})
    refute has_element?(view, ".file-list .file-name", "src/widget.rs")

    render_hook(view, "filter.toggle_file", %{"file_name" => "src/widget.rs"})
    assert has_element?(view, ".file-list .file-name", "src/widget.rs")
    refute has_element?(view, ".file-list .file-name", "other.ex")
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

  test "hide *.md hides the markdown file until its chip is clicked", %{conn: conn} do
    repo = tmp_git_repo()
    commit(repo, "init")
    stage(repo, "NOTES.md", "# Notes\n")
    stage(repo, "src/main.rs", "fn main() {}\n")
    {:ok, state} = ReviewState.from_target({:staged, nil}, repo)
    {view, _rid} = mount_bound(conn, state, repo)
    open_files_panel(view)
    refute has_element?(view, ".hidden-extensions .filter-chip")

    view |> element(".hide-ext-btn[phx-value-ext=md]") |> render_click()
    refute has_element?(view, ".file-list .file-name", "NOTES.md")
    assert has_element?(view, ".file-list .file-name", "src/main.rs")
    assert has_element?(view, ".hidden-extensions .filter-chip", ".md ×")

    view |> element(".hidden-extensions .filter-chip", ".md ×") |> render_click()
    assert has_element?(view, ".file-list .file-name", "NOTES.md")
    refute has_element?(view, ".hidden-extensions .filter-chip")
  end

  test "generated files stay hidden until the generated chip shows them", %{conn: conn} do
    repo = tmp_git_repo()
    stage(repo, ".gitattributes", "bun.lock linguist-generated=true\n")
    commit(repo, "seed attrs")
    stage(repo, "bun.lock", "fresh lockfile contents\n")
    stage(repo, "src.ts", "export const greeting = 'hi';\n")
    {:ok, state} = ReviewState.from_target({:staged, nil}, repo)
    {view, _rid} = mount_bound(conn, state, repo)

    assert has_element?(view, ".file-list .file-name", "src.ts")
    refute has_element?(view, ".file-list .file-name", "bun.lock")

    open_files_panel(view)
    chip = element(view, ".file-filter .filter-chip", "generated")
    assert has_element?(view, ".file-filter .filter-chip", ~r/generated\s*×/)

    render_click(chip)
    assert has_element?(view, ".file-filter .filter-chip", ~r/generated\s*✓/)
    assert has_element?(view, ".file-list .file-name", "bun.lock")
    assert has_element?(view, ".file-list .file-name", "src.ts")

    render_click(chip)
    assert has_element?(view, ".file-filter .filter-chip", ~r/generated\s*×/)
    refute has_element?(view, ".file-list .file-name", "bun.lock")
    assert has_element?(view, ".file-list .file-name", "src.ts")
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
    refute_push_event(view, "scroll-into-view", _, 0)
  end

  test "file.toggle_expanded flips the collapse set for approved and unapproved files", %{
    conn: conn
  } do
    repo = tmp_git_repo()

    {view, _rid} =
      mount_bound(conn, %ReviewState{files: [%{@plain_file | effective_oid: nil}]}, repo)

    header = element(view, "#file-0 button.file-row")

    # Unapproved → expanded by default; the header collapses it and a
    # second click re-expands it.
    assert has_element?(view, "#DiffViewer-0")
    render_click(header)
    assert has_element?(view, "#file-0.collapsed")
    refute has_element?(view, "#DiffViewer-0")
    render_click(header)
    refute has_element?(view, "#file-0.collapsed")
    assert has_element?(view, "#DiffViewer-0")

    # Approving collapses the file; the header expands it.
    view |> element("#file-0 .approved-toggle input") |> render_click()
    assert has_element?(view, "#file-0.approved.collapsed")
    refute has_element?(view, "#DiffViewer-0")
    render_click(header)
    refute has_element?(view, "#file-0.collapsed")
    assert has_element?(view, "#DiffViewer-0")
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

    refute_push_event(view, "open-url", _, 0)
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
    refute_push_event(view2, "scroll-into-view", _, 0)
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

  test "an approve after another tab's decision marks no file approved", %{conn: conn} do
    repo = tmp_git_repo()
    state = %ReviewState{files: [%{@plain_file | effective_oid: "oid1"}], head_branch: "main"}
    {view, _rid} = mount_bound(conn, state, repo)
    {:ok, _} = Decision.submit({:reject, "feedback"})

    render_click(view, "decision.approve", %{})

    assert Decision.current() == {:reject, "feedback"}
    refute ApprovalCache.approved?(ApprovalCache.load_for(repo), "main", "src/widget.rs", "oid1")
  end

  test "approve outside a git repo skips the approval cache and still decides", %{conn: conn} do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-lv-nogit")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    assert ApprovalCache.path_for(dir) == nil

    Application.put_env(:meerkat, :repo_path, dir)
    view = mount_unbound(conn, %ReviewState{files: [@plain_file], head_branch: "main"})

    render_click(view, "decision.approve", %{})
    assert Decision.current() == {:approve, ""}
  end

  test "editing a comment that no longer exists opens no form", %{conn: conn} do
    view = mount_unbound(conn)

    render_click(view, "comment_form.edit", %{"surface" => "global", "id" => "gone"})

    refute has_element?(view, ".dirty-form-link")
  end

  test "filter.show_only with a non-integer index is logged and changes nothing", %{conn: conn} do
    state = %ReviewState{files: [@plain_file, %{@plain_file | file_name: "other.ex"}]}
    view = mount_unbound(conn, state)

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        render_hook(view, "filter.show_only", %{"file_index" => "x"})
      end)

    assert stderr =~ "filter.show_only ignored"
    assert has_element?(view, ".file-list .file-name", "src/widget.rs")
    assert has_element?(view, ".file-list .file-name", "other.ex")
  end
end
