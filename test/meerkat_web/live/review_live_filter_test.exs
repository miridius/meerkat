defmodule MeerkatWeb.ReviewLiveFilterTest do
  # Drives `MeerkatWeb.ReviewLive`'s approval, file-filter and file-panel
  # event handlers, then the mutant kills of the third mutation pass,
  # which span every surface; `MeerkatWeb.ReviewLiveEventsCase` describes
  # the setup.

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
      approval_key: "main",
      precommit?: true
    }

    {view, rid} = mount_bound(conn, state, repo)

    html = render_hook(view, "file.toggle_approved", %{"file_name" => "src_widget.rs"})
    refute html =~ "didn&#39;t persist"
    # The reply itself collapses the section, ahead of the scroll it pushes.
    assert html =~ ~s(class="file-section approved collapsed")
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

  test "on a detached HEAD, an approved file stays approved in the next review round", %{
    conn: conn
  } do
    repo = tmp_git_repo()
    commit(repo, "seed")
    git(repo, ["checkout", "-q", "--detach"])
    stage(repo, "a.txt", "alpha\n")
    stage(repo, "b.txt", "bravo\n")

    {:ok, round1} = ReviewState.from_target({:staged, nil}, repo)
    assert round1.head_branch == nil
    {view, _rid} = mount_bound(conn, round1, repo)

    view
    |> element(".approved-toggle input[phx-value-file_name='a.txt']")
    |> render_click()

    stage(repo, "b.txt", "bravo v2\n")
    {:ok, round2} = ReviewState.from_target({:staged, nil}, repo)
    assert round2.approved_file_names == MapSet.new(["a.txt"])
    assert Map.keys(ApprovalCache.load_for(repo)) == ["detached HEAD (.git)"]
  end

  test "approving a file with no effective_oid flashes instead of silently not persisting", %{
    conn: conn
  } do
    repo = state_repo()
    Application.put_env(:meerkat, :repo_path, repo)

    view =
      mount_unbound(conn, %ReviewState{
        files: [%{@plain_file | effective_oid: nil}],
        approval_key: "main",
        precommit?: true
      })

    html = render_hook(view, "file.toggle_approved", %{"file_name" => "src/widget.rs"})
    assert html =~ "didn&#39;t persist"
  end

  test "ticking Approved in a PR / range review leaves the approval cache alone", %{conn: conn} do
    repo = state_repo()

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

    put_state(%ReviewState{
      files: [%{@plain_file | effective_oid: nil}],
      approval_key: "main",
      precommit?: true
    })

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
      approval_key: "main",
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
    repo = state_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    render_hook(view, "filter.show_only", %{"file_index" => "0"})
    render_click(view, "filter.show_all", %{})
    assert ReviewServer.get_state(rid).file_overrides == %{}
  end

  test "filter.toggle_file writes :hide for a visible file and :show for a hidden one", %{
    conn: conn
  } do
    repo = state_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    render_hook(view, "filter.toggle_file", %{"file_name" => "src/widget.rs"})
    assert ReviewServer.get_state(rid).file_overrides == %{"src/widget.rs" => :hide}

    render_hook(view, "filter.toggle_file", %{"file_name" => "src/widget.rs"})
    assert ReviewServer.get_state(rid).file_overrides == %{"src/widget.rs" => :show}
  end

  test "filter.toggle_file shows a file that show-only hides", %{conn: conn} do
    repo = state_repo()
    state = %ReviewState{files: [@plain_file, %{@plain_file | file_name: "other.ex"}]}
    {view, _rid} = mount_bound(conn, state, repo)

    render_hook(view, "filter.show_only", %{"file_index" => "1"})
    refute has_element?(view, ".file-list .file-name", "src/widget.rs")

    render_hook(view, "filter.toggle_file", %{"file_name" => "src/widget.rs"})
    assert has_element?(view, ".file-list .file-name", "src/widget.rs")
    assert has_element?(view, ".file-list .file-name", "other.ex")
  end

  test "filter.toggle_file re-showing the show-only file keeps show-only", %{conn: conn} do
    repo = state_repo()
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
    repo = state_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    render_hook(view, "filter.toggle_file", %{"file_name" => "nope.ex"})
    assert ReviewServer.get_state(rid).file_overrides == %{}
  end

  test "filter.hide_matched / show_matched scope to the substring filter", %{conn: conn} do
    repo = state_repo()

    state = %ReviewState{files: [@plain_file, %{@plain_file | file_name: "other.ex"}]}

    {view, rid} = mount_bound(conn, state, repo)

    render_hook(view, "filter.set_input", %{"value" => "widget"})
    render_click(view, "filter.hide_matched", %{})
    assert ReviewServer.get_state(rid).file_overrides == %{"src/widget.rs" => :hide}

    render_click(view, "filter.show_matched", %{})
    assert ReviewServer.get_state(rid).file_overrides == %{"src/widget.rs" => :show}
  end

  test "hide *.md hides the markdown file until its chip is clicked", %{conn: conn} do
    state = %ReviewState{
      files: [added("NOTES.md", "# Notes\n"), added("src/main.rs", "fn main() {}\n")]
    }

    {view, _rid} = mount_bound(conn, state, state_repo())
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
    lock = %{added("bun.lock", "fresh lockfile contents\n") | is_generated: true}
    state = %ReviewState{files: [lock, added("src.ts", "export const greeting = 'hi';\n")]}
    {view, _rid} = mount_bound(conn, state, state_repo())

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

  test "the Files button opens and closes the dropdown without scrolling the page", %{
    conn: conn
  } do
    view = mount_unbound(conn)
    refute has_element?(view, "#file-filter")
    assert has_element?(view, "#files-toggle[aria-expanded=false]")
    refute has_element?(view, "#files-toggle[aria-controls]")
    refute has_element?(view, ".files-dropdown[phx-click-away]")

    open_files_panel(view)
    assert has_element?(view, "#file-filter")
    assert has_element?(view, "#files-toggle[aria-expanded=true][aria-controls=file-filter]")
    # Clicking outside the button and dropdown closes it.
    assert has_element?(view, ".files-dropdown[phx-click-away='files.close']")
    refute_push_event(view, "scroll-into-view", _, 0)

    open_files_panel(view)
    refute has_element?(view, "#file-filter")
    assert has_element?(view, "#files-toggle[aria-expanded=false]")
  end

  test "Escape and files.close close the dropdown", %{conn: conn} do
    view = mount_unbound(conn)

    open_files_panel(view)
    view |> element("#file-filter") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#file-filter")

    open_files_panel(view)
    render_hook(view, "files.close", %{})
    refute has_element?(view, "#file-filter")

    open_files_panel(view)
    view |> element(".file-filter-toggle") |> render_click()
    refute has_element?(view, "#file-filter")
  end

  test "the dropdown shows a folder tree of base names that folders collapse", %{conn: conn} do
    files = [
      @plain_file,
      %{@plain_file | file_name: "src/a/deep/x.rs"},
      %{@plain_file | file_name: "README.md"}
    ]

    view = mount_unbound(conn, %ReviewState{files: files})
    open_files_panel(view)

    assert has_element?(view, ".tree-dir[aria-expanded=true]", "src")
    # A folder whose only child is a folder shares its row.
    assert has_element?(view, ".tree-dir[phx-value-path='src/a/deep']", "a/deep")
    # Rows are indented by depth.
    assert has_element?(view, ".tree-dir[phx-value-path=src][style='--depth: 0']")
    assert has_element?(view, ".tree-dir[phx-value-path='src/a/deep'][style='--depth: 1']")
    assert has_element?(view, ".file-entry[style='--depth: 2']", "x.rs")
    assert has_element?(view, ".file-entry .base-name", "widget.rs")
    refute has_element?(view, ".file-entry .base-name", "src/widget.rs")
    assert has_element?(view, ".file-entry .base-name", "README.md")

    view |> element(".tree-dir[phx-value-path=src]") |> render_click()
    assert has_element?(view, ".tree-dir[phx-value-path=src][aria-expanded=false]")
    refute has_element?(view, ".file-entry .base-name", "widget.rs")
    refute has_element?(view, ".tree-dir[phx-value-path='src/a/deep']")
    assert has_element?(view, ".file-entry .base-name", "README.md")

    # Filtering shows every match, even in a collapsed folder; clearing
    # the filter collapses it again.
    view |> element(".file-filter form") |> render_change(%{"value" => "widget"})
    assert has_element?(view, ".tree-dir[phx-value-path=src][aria-expanded=true]")
    assert has_element?(view, ".file-entry .base-name", "widget.rs")
    refute has_element?(view, ".file-entry .base-name", "x.rs")

    # While filtering, a folder click collapses it for this filter text only.
    view |> element(".tree-dir[phx-value-path=src]") |> render_click()
    assert has_element?(view, ".tree-dir[phx-value-path=src][aria-expanded=false]")
    refute has_element?(view, ".file-entry .base-name", "widget.rs")
    view |> element(".file-filter form") |> render_change(%{"value" => "widget"})
    assert has_element?(view, ".tree-dir[phx-value-path=src][aria-expanded=false]")
    view |> element(".file-filter form") |> render_change(%{"value" => "widge"})
    assert has_element?(view, ".file-entry .base-name", "widget.rs")

    # Enter applies the text rather than submitting the form natively.
    view |> element(".file-filter form") |> render_submit(%{"value" => "x.rs"})
    assert has_element?(view, ".file-entry .base-name", "x.rs")
    refute has_element?(view, ".file-entry .base-name", "widget.rs")

    view |> element(".file-filter form") |> render_change(%{"value" => ""})
    refute has_element?(view, ".file-entry .base-name", "widget.rs")
    assert has_element?(view, ".tree-dir[phx-value-path=src][aria-expanded=false]")

    # Collapsed folders stay collapsed when the dropdown reopens.
    open_files_panel(view)
    open_files_panel(view)
    assert has_element?(view, ".tree-dir[phx-value-path=src][aria-expanded=false]")

    view |> element(".tree-dir[phx-value-path=src]") |> render_click()
    assert has_element?(view, ".file-entry .base-name", "widget.rs")
  end

  test "picking a file closes the dropdown and scrolls to and focuses its section",
       %{conn: conn} do
    view =
      mount_unbound(conn, %ReviewState{files: [@plain_file, %{@plain_file | file_name: "b.ex"}]})

    open_files_panel(view)

    view |> element(".file-entry .file-path", "b.ex") |> render_click()
    refute has_element?(view, "#file-filter")
    assert_push_event(view, "scroll-into-view", %{id: "file-1", focus: true})
  end

  test "picking a file the main list hides closes the dropdown without scrolling",
       %{conn: conn} do
    files = [@plain_file, %{@plain_file | file_name: "b.ex"}]
    view = mount_unbound(conn, %ReviewState{files: files, file_overrides: %{"b.ex" => :hide}})
    open_files_panel(view)

    view |> element(".file-entry .file-path", "b.ex") |> render_click()
    refute has_element?(view, "#file-filter")
    refute_push_event(view, "scroll-into-view", _, 0)
    assert_push_event(view, "focus", %{id: "files-toggle"})
  end

  test "picking a file hidden while another is shown alone closes the dropdown without scrolling",
       %{conn: conn} do
    view =
      mount_unbound(conn, %ReviewState{files: [@plain_file, %{@plain_file | file_name: "b.ex"}]})

    render_hook(view, "filter.show_only", %{"file_index" => "0"})
    open_files_panel(view)

    view |> element(".file-entry .file-path", "b.ex") |> render_click()
    refute has_element?(view, "#file-filter")
    refute_push_event(view, "scroll-into-view", _, 0)
    assert_push_event(view, "focus", %{id: "files-toggle"})
  end

  test "files.pick ignores a non-integer index", %{conn: conn} do
    view = mount_unbound(conn)
    open_files_panel(view)

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        render_hook(view, "files.pick", %{"file_index" => "x"})
      end)

    assert stderr =~ ~s(files.pick ignored — non-integer file_index: "x")
    assert has_element?(view, "#file-filter")
    refute_push_event(view, "scroll-into-view", _, 0)
  end

  test "file.toggle_expanded flips the collapse set for approved and unapproved files", %{
    conn: conn
  } do
    repo = state_repo()

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

  test "collapsing a file scrolls to the next shown file, or to its own when none follows", %{
    conn: conn
  } do
    files = for name <- ~w(a b c d), do: %{@plain_file | file_name: name, effective_oid: nil}
    view = mount_unbound(conn, %ReviewState{files: files, file_overrides: %{"b" => :hide}})
    toggle = &render_click(view, "file.toggle_expanded", %{"file_name" => &1})

    # b is hidden, so a's next shown file is c.
    toggle.("a")
    assert_push_event(view, "scroll-into-view", %{id: "file-2"})
    toggle.("d")
    assert_push_event(view, "scroll-into-view", %{id: "file-3"})

    # Expanding, or a file the review lacks, does not scroll.
    toggle.("a")
    toggle.("nope")
    refute_push_event(view, "scroll-into-view", _, 0)
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
    repo = state_repo()
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

  test "un-approving does not push the scroll nudge; approving scrolls to the next file", %{
    conn: conn
  } do
    repo = state_repo()

    state = %ReviewState{
      files: [
        %{@plain_file | effective_oid: nil},
        %{@plain_file | file_name: "src/next.rs", effective_oid: nil}
      ],
      head_branch: "main"
    }

    put_state(state)
    Application.put_env(:meerkat, :repo_path, repo)
    {:ok, view, _html} = live_isolated(conn, ReviewLive)

    render_hook(view, "file.toggle_approved", %{"file_name" => "src/widget.rs"})
    assert_push_event(view, "scroll-into-view", %{id: "file-1"})

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

  test "re-approving a file expanded while approved collapses it again", %{conn: conn} do
    state = %ReviewState{
      files: [
        %{@plain_file | effective_oid: nil},
        %{@plain_file | file_name: "src/other.rs", effective_oid: nil}
      ],
      head_branch: "main",
      approved_file_names: MapSet.new(["src/widget.rs", "src/other.rs"])
    }

    {view, _rid} = mount_bound(conn, state, state_repo())

    toggle_approved = fn ->
      render_hook(view, "file.toggle_approved", %{"file_name" => "src/widget.rs"})
    end

    for name <- ["src/widget.rs", "src/other.rs"],
        do: render_click(view, "file.toggle_expanded", %{"file_name" => name})

    refute has_element?(view, "#file-0.collapsed")
    toggle_approved.()
    toggle_approved.()
    assert has_element?(view, "#file-0.collapsed")
    # Only the re-approved file loses its expansion.
    refute has_element?(view, "#file-1.collapsed")
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
    repo = state_repo()

    state = %ReviewState{
      files: [
        %{@plain_file | file_name: "staged.ex", effective_oid: "oid1"},
        %{@plain_file | file_name: "blank.ex", effective_oid: ""}
      ],
      approval_key: "main"
    }

    {view, _rid} = mount_bound(conn, state, repo)

    render_click(view, "decision.approve", %{})
    cache = ApprovalCache.load_for(repo)
    assert ApprovalCache.approved?(cache, "main", "staged.ex", "oid1")
    # A blank oid would content-address nothing — it must not be cached.
    refute ApprovalCache.approved?(cache, "main", "blank.ex", "")
    refute Map.has_key?(cache["main"] || %{}, "blank.ex")
  end

  test "approving a PR / range review leaves the approval cache alone", %{conn: conn} do
    repo = tmp_git_repo()
    state = %ReviewState{files: [%{@plain_file | effective_oid: "oid1"}], head_branch: "feature"}
    {view, _rid} = mount_bound(conn, state, repo)

    render_click(view, "decision.approve", %{})

    assert Decision.current() == {:approve, ""}
    refute File.exists?(ApprovalCache.path_for(repo))
  end

  test "approving on a detached HEAD writes under the worktree's key", %{conn: conn} do
    repo = tmp_git_repo()
    key = "detached HEAD (.git)"
    state = %ReviewState{files: [%{@plain_file | effective_oid: "oid1"}], approval_key: key}
    {view, _rid} = mount_bound(conn, state, repo)

    render_click(view, "decision.approve", %{})

    cache = ApprovalCache.load_for(repo)
    assert Map.keys(cache) == [key]
    assert ApprovalCache.approved?(cache, key, "src/widget.rs", "oid1")
  end

  test "an approve after another tab's decision marks no file approved", %{conn: conn} do
    repo = state_repo()
    state = %ReviewState{files: [%{@plain_file | effective_oid: "oid1"}], approval_key: "main"}
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
    view = mount_unbound(conn, %ReviewState{files: [@plain_file], approval_key: "main"})

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
