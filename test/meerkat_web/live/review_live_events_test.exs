defmodule MeerkatWeb.ReviewLiveEventsTest do
  # Drives `MeerkatWeb.ReviewLive`'s toolbar, page and decision event
  # handlers; `MeerkatWeb.ReviewLiveEventsCase` describes the setup.
  # These kill the handler mutants muex found once these tests were
  # visible to its dependency analysis.
  #
  # --- Documented surviving mutants (CLAUDE.md, Mutation testing) ---
  #
  # Equivalent (no input distinguishes mutant from original):
  # * `attr` declarations in function components `flag_toggles`, `flag_toggle`,
  #   `flash_error_banner`, `pending_answers_banner`, `version_chip`,
  #   `commit_message_section`,
  #   `global_comments_section`,
  #   `file_list`, `markdown_preview`, `file_filter`, and `diff_toolbar` —
  #   deleting an `attr` line removes compile-time validation metadata
  #   only; with every call site passing its assigns, no runtime behaviour
  #   differs. `markdown_preview`'s `:read_errors` attr default is never
  #   used because its only caller always passes `read_errors`.

  use MeerkatWeb.ReviewLiveEventsCase

  alias Meerkat.{ApprovalCache, Decision, PendingAnswers, ReviewServer, ReviewState}
  alias MeerkatWeb.ReviewLive
  import Meerkat.TestHelpers, only: [git: 2, stage: 3]

  @plain_file plain_file()
  @commit_msg commit_msg()

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
    assert saved_settings() == %{"tab_size" => 8}
    assert render_click(view, "toolbar.set_tab_size", %{"n" => "3"}) =~ "8"
  end

  test "the ⚙ rulers setting reaches the diff and every comment form, and is saved",
       %{conn: conn} do
    state = %ReviewState{
      files: [@plain_file],
      commit_message: "subject",
      commit_message_blocks: [%{start_line: 1, end_line: 1, text: "subject"}]
    }

    view = mount_unbound(conn, state)
    render_click(view, "comment_form.show_global", %{})
    render_click(view, "comment_form.show_file", %{"file_index" => "0"})

    html =
      render_hook(view, "comment_form.show_commit_msg", %{"start_line" => "1", "end_line" => "1"})

    ids = [
      "DiffViewer-0",
      "CommentForm-global",
      "CommentForm-file-0",
      "CommentForm-commit_msg-1-1"
    ]

    rulers = fn html -> Map.new(ids, &{&1, svelte_props(html, &1) |> rulers_prop()}) end

    # Later renders carry only changed props, so only the form this
    # render mounted shows its initial columns.
    assert rulers_prop(svelte_props(html, "CommentForm-commit_msg-1-1")) == [80, 110]
    assert has_element?(view, ".rulers-toggle input[type=checkbox][checked]")
    assert has_element?(view, "input[name=columns][value='80, 110'][aria-invalid=false]")

    # Commas and spaces separate columns; the list is sorted and deduped.
    html = view |> element("#ruler-columns-form") |> render_change(%{"columns" => "120 72,72"})
    assert rulers.(html) == Map.new(ids, &{&1, [72, 120]})
    assert has_element?(view, "input[name=columns][value='72, 120']")
    assert saved_settings() == %{"ruler_columns" => [72, 120]}

    # Unchecking hides them without forgetting the columns.
    html = view |> element(".rulers-toggle input[type=checkbox]") |> render_click()
    assert rulers.(html) == Map.new(ids, &{&1, []})
    assert has_element?(view, "input[name=columns][value='72, 120']")
    assert saved_settings() == %{"ruler_columns" => [72, 120], "rulers" => false}

    # Junk stays in the field, marked, through other changes, and the
    # last list stays in force.
    view |> element("#ruler-columns-form") |> render_change(%{"columns" => "80, wide"})
    html = view |> element(".rulers-toggle input[type=checkbox]") |> render_click()
    assert rulers.(html) == Map.new(ids, &{&1, [72, 120]})
    assert has_element?(view, "input[name=columns][value='80, wide'][aria-invalid=true]")

    # A blank field means no rulers, and clears the mark.
    html = view |> element("#ruler-columns-form") |> render_submit(%{"columns" => " "})
    assert rulers.(html) == Map.new(ids, &{&1, []})
    assert has_element?(view, "input[name=columns][aria-invalid=false]")
  end

  test "a tab opens with the saved settings", %{conn: conn} do
    Meerkat.Settings.put(:rulers, false)
    Meerkat.Settings.put(:ruler_columns, [100])
    Meerkat.Settings.put(:wrap_lines, false)
    view = mount_unbound(conn)
    refute has_element?(view, ".rulers-toggle input[type=checkbox][checked]")
    assert has_element?(view, "input[name=columns][value='100']")
    # A rejoin leaves a focused field's text alone, so the hook gets it too.
    assert_push_event(view, "ruler-columns:set", %{text: "100"})
    refute has_element?(view, ".wrap-toggle input[checked]")
  end

  test "a change in one tab applies in the review's other tabs", %{conn: conn} do
    view = mount_unbound(conn)
    other = mount_unbound(conn)
    assert_push_event(view, "ruler-columns:set", %{text: "80, 110"})
    assert_push_event(other, "ruler-columns:set", %{text: "80, 110"})
    other |> element("#ruler-columns-form") |> render_change(%{"columns" => "80, wide"})

    view |> element(".diff-toolbar > .view-controls .wrap-toggle input") |> render_click()
    refute has_element?(other, ".wrap-toggle input[checked]")
    # A change to another setting leaves the other tab's field alone.
    assert has_element?(other, "input[name=columns][value='80, wide'][aria-invalid=true]")
    refute_push_event(other, "ruler-columns:set", _)

    view |> element("#ruler-columns-form") |> render_change(%{"columns" => "100 60"})
    assert has_element?(other, "input[name=columns][value='60, 100'][aria-invalid=false]")
    assert svelte_props(render(other), "DiffViewer-0") |> rulers_prop() == [60, 100]
    # The field may be focused, so its text also goes to the hook.
    assert_push_event(other, "ruler-columns:set", %{text: "60, 100"})
    refute_push_event(view, "ruler-columns:set", _)
  end

  test "set_diff_mode flips the active segment", %{conn: conn} do
    view = mount_unbound(conn)
    html = render_click(view, "set_diff_mode", %{"mode" => "unified"})
    assert html =~ "active"
    assert saved_settings() == %{"diff_mode" => "unified"}
  end

  test "the Wrap toggle starts checked and unchecks on click", %{conn: conn} do
    view = mount_unbound(conn)
    assert has_element?(view, ".diff-toolbar > .view-controls .wrap-toggle input[checked]")

    view |> element(".diff-toolbar > .view-controls .wrap-toggle input") |> render_click()
    refute has_element?(view, ".diff-toolbar > .view-controls .wrap-toggle input[checked]")
    assert saved_settings() == %{"wrap_lines" => false}
  end

  # The toolbar moves them there when it is short of room.
  test "the ⚙ popover's Split / Unified and Wrap set and show the same settings", %{conn: conn} do
    view = mount_unbound(conn)
    popover = ".toolbar-settings-popover .view-controls"
    assert has_element?(view, "#{popover} button.active", "Split")
    assert has_element?(view, "#{popover} .wrap-toggle input[checked]")

    view |> element("#{popover} button", "Unified") |> render_click()
    view |> element("#{popover} .wrap-toggle input") |> render_click()

    for controls <- [popover, ".diff-toolbar > .view-controls"] do
      assert has_element?(view, "#{controls} button.active", "Unified")
      refute has_element?(view, "#{controls} .wrap-toggle input[checked]")
    end
  end

  test "the version chip shows a dev label with no changelog, or a release's commit and PR links",
       %{conn: conn} do
    prev = System.get_env("RELEASE_ROOT")

    on_exit(fn ->
      if prev, do: System.put_env("RELEASE_ROOT", prev), else: System.delete_env("RELEASE_ROOT")
    end)

    System.delete_env("RELEASE_ROOT")
    view = mount_unbound(conn)
    assert has_element?(view, ".version-chip-btn .chip-value", ~r/^dev: /)
    assert has_element?(view, ".version-chip-btn[disabled]")

    root =
      Meerkat.TestHelpers.tmp_path("meerkat-lv-release")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, "meerkat_version"), """
    abc1234567890
    https://github.com/miridius/meerkat
    Live-restart a review onto a newly-installed version (#11)
    Install versioned releases (#10)
    """)

    System.put_env("RELEASE_ROOT", root)
    view = mount_unbound(conn)
    assert has_element?(view, ".version-chip-btn .chip-value", ~r/^abc1234$/)
    refute has_element?(view, ".version-chip-btn[disabled]")
    # The VersionChip hook reveals the popover on click.
    assert has_element?(view, ".version-popover[hidden]")

    assert has_element?(
             view,
             ".version-popover a[href='https://github.com/miridius/meerkat/pull/11']",
             ~r/#11\s+Live-restart a review/
           )

    assert has_element?(
             view,
             ".version-popover a[href='https://github.com/miridius/meerkat/pull/10']",
             ~r/#10\s+Install versioned releases/
           )
  end

  test "the toolbar links the review's PR and names its branches, whole on hover",
       %{conn: conn} do
    url = "https://github.com/example/example/pull/77"

    view =
      mount_unbound(conn, %ReviewState{
        files: [@plain_file],
        pr: %{number: 77, title: "PR 77", url: url},
        base_branch: "main",
        head_branch: "feature/rebased"
      })

    assert has_element?(view, ~s(a.chip-link[href="#{url}"] .chip-value), ~r/^#77$/)
    assert has_element?(view, ~s(.branch-chip .chip-value[title="main"]), ~r/^main$/)

    assert has_element?(
             view,
             ~s(.branch-chip .chip-value[title="feature/rebased"]),
             ~r/^feature\/rebased$/
           )

    view = mount_unbound(conn, %ReviewState{files: [@plain_file], head_branch: "fix/typo"})
    refute has_element?(view, "a.chip-link")
    assert has_element?(view, ~s(.branch-chip .chip-value[title="fix/typo"]), ~r/^fix\/typo$/)
  end

  ## --- Page ---

  test "a staged review renders its file rows, commit-message gutter and decision buttons", %{
    conn: conn
  } do
    repo = tmp_git_repo()
    commit(repo, "init")
    stage(repo, "NOTES.md", "# Notes\n")
    stage(repo, "src/main.rs", "fn main() {}\n")
    msg_path = Path.join(repo, "COMMIT_EDITMSG")
    File.write!(msg_path, @commit_msg)
    {:ok, state} = ReviewState.from_target({:staged, msg_path}, repo)
    view = mount_unbound(conn, state)

    assert has_element?(view, "button.file-row", ~r/^\s*▾\s*A\s*NOTES\.md\s*\+1\s*-0\s*$/)
    assert has_element?(view, "button.file-row", ~r/^\s*▾\s*A\s*src\/main\.rs\s*\+1\s*-0\s*$/)

    labels = [
      "Comment on commit message line 1",
      "Comment on commit message lines 3 through 4",
      "Comment on commit message line 6",
      "Comment on commit message line 7"
    ]

    for label <- labels do
      assert has_element?(view, "button.gutter-line-num[aria-label='#{label}']")
    end

    assert count(view, "button.gutter-line-num") == length(labels)

    assert has_element?(view, "button.approve-btn", ~r/^\s*Approve\s*$/)
    assert has_element?(view, "button.reject-btn", ~r/^\s*Send Feedback\s*$/)
    assert has_element?(view, "button.cancel-btn", ~r/^\s*Cancel\s*$/)
  end

  test "a single-ref review shows that commit's files and message", %{conn: conn} do
    repo = tmp_git_repo()
    stage(repo, "base.txt", "base\n")
    commit(repo, "Base")
    stage(repo, "added-by-feature.rs", "fn feature() {}\n")
    commit(repo, "Add feature module")

    {:ok, state} = ReviewState.from_target({:single_ref, "HEAD"}, repo)
    view = mount_unbound(conn, state)

    assert has_element?(
             view,
             "button.file-row",
             ~r/^\s*▾\s*A\s*added-by-feature\.rs\s*\+1\s*-0\s*$/
           )

    refute has_element?(view, "button.file-row", "base.txt")

    assert has_element?(
             view,
             "button.gutter-line-num[aria-label='Comment on commit message line 1']"
           )
  end

  test "a two-dot range review shows only the files changed between the refs", %{conn: conn} do
    repo = tmp_git_repo()
    stage(repo, "first.txt", "first commit body\n")
    commit(repo, "First commit")
    stage(repo, "second.txt", "second commit body\n")
    commit(repo, "Second commit")

    {:ok, state} = ReviewState.from_target({:range, "HEAD~1", "HEAD", :two_dot}, repo)
    view = mount_unbound(conn, state)

    assert has_element?(view, "button.file-row", ~r/^\s*▾\s*A\s*second\.txt\s*\+1\s*-0\s*$/)
    refute has_element?(view, "button.file-row", "first.txt")
  end

  test "a range review lists a non-UTF-8 binary file without line counts", %{conn: conn} do
    repo = tmp_git_repo()
    stage(repo, "logo.bin", <<0, 255, 1>>)
    commit(repo, "base")
    stage(repo, "logo.bin", <<0, 254, 2>>)
    stage(repo, "a.txt", "a\n")
    commit(repo, "head")

    {:ok, state} = ReviewState.from_target({:range, "HEAD~1", "HEAD", :two_dot}, repo)
    view = mount_unbound(conn, state)

    assert has_element?(view, "button.file-row", ~r/^\s*▾\s*M\s*logo\.bin\s*$/)
    assert has_element?(view, "button.file-row", ~r/^\s*▾\s*A\s*a\.txt\s*\+1\s*-0\s*$/)
  end

  test "the toolbar sums every file's line counts and a binary file's header shows none", %{
    conn: conn
  } do
    repo = tmp_git_repo()
    stage(repo, "a.txt", "one\ntwo\nthree\n")
    stage(repo, "logo.bin", <<0, 1, 2>>)
    commit(repo, "base")
    stage(repo, "a.txt", "one\nTWO\nthree\nfour\n")
    stage(repo, "logo.bin", <<0, 1, 3>>)
    stage(repo, "b.txt", "new\n")
    {:ok, state} = ReviewState.from_target({:staged, nil}, repo)

    view = mount_unbound(conn, state)
    assert has_element?(view, ".toolbar-line-counts", ~r/^\s*\+3\s*-1\s*$/)
    assert has_element?(view, "button.file-row", ~r/^\s*▾\s*M\s*a\.txt\s*\+2\s*-1\s*$/)
    assert has_element?(view, "button.file-row", ~r/^\s*▾\s*A\s*b\.txt\s*\+1\s*-0\s*$/)
    assert has_element?(view, "button.file-row", ~r/^\s*▾\s*M\s*logo\.bin\s*$/)
  end

  test "the toolbar shows the counts of the expanded files the filter shows, of the whole diff's",
       %{conn: conn} do
    repo = tmp_git_repo()
    stage(repo, "a.txt", "one\ntwo\n")
    stage(repo, "c.md", "x\n")
    commit(repo, "base")
    stage(repo, "a.txt", "one\nTWO\nthree\n")
    stage(repo, "b.txt", "new\n")
    stage(repo, "c.md", "")
    {:ok, state} = ReviewState.from_target({:staged, nil}, repo)

    view = mount_unbound(conn, %{state | hidden_extensions: MapSet.new(["md"])})

    assert has_element?(
             view,
             ".toolbar-line-counts",
             ~r/^\s*showing\s*\+3\s*-1\s*of\s*\/\s*\+3\s*-2\s*$/
           )

    view |> element("button.file-row", "b.txt") |> render_click()

    assert has_element?(
             view,
             ".toolbar-line-counts",
             ~r/^\s*showing\s*\+2\s*-1\s*of\s*\/\s*\+3\s*-2\s*$/
           )

    view = mount_unbound(conn, %{state | approved_file_names: MapSet.new(["a.txt"])})

    assert has_element?(
             view,
             ".toolbar-line-counts",
             ~r/^\s*showing\s*\+1\s*-1\s*of\s*\/\s*\+3\s*-2\s*$/
           )
  end

  test "pending answers render as a banner with markdown questions and answers", %{conn: conn} do
    repo = tmp_git_repo()

    answers = %{
      answers: [
        %{
          location: "src/main.rs:1 (new)",
          question: "Why the `use std::fmt`?",
          answer: "It backs the Display impl below."
        }
      ]
    }

    {:ok, 1} = PendingAnswers.save(repo, Jason.encode!(answers))
    {view, _rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    assert has_element?(view, "section.pending-answers h2", ~r/^\s*Pending answers \(1\)\s*$/)

    assert has_element?(
             view,
             "section.pending-answers .location",
             ~r/^\s*src\/main\.rs:1 \(new\)\s*$/
           )

    assert has_element?(view, "section.pending-answers .question", "Why the use std::fmt?")
    assert has_element?(view, "section.pending-answers .question code", "use std::fmt")

    assert has_element?(
             view,
             "section.pending-answers .answer",
             "It backs the Display impl below."
           )
  end

  test "a staged rename's header names the old path and its diff gets both sides", %{conn: conn} do
    repo = tmp_git_repo()
    # Mostly-unchanged body so git pairs the paths as a rename.
    body = Enum.map_join(0..8, "\n", &"fn shared_#{&1}() {}")
    stage(repo, "src/old_name.rs", "fn original() {}\n#{body}\n")
    commit(repo, "base")
    git(repo, ["mv", "src/old_name.rs", "src/new_name.rs"])
    stage(repo, "src/new_name.rs", "fn renamed_fn() {}\n#{body}\n")
    {:ok, state} = ReviewState.from_target({:staged, nil}, repo)

    view = mount_unbound(conn, state)

    assert has_element?(view, "#file-0 button.file-row", ~r/▾\s*R\s*src\/new_name\.rs/)
    assert has_element?(view, "#file-0 .rename-from", ~r/^\s*\(was src\/old_name\.rs\)\s*$/)

    assert %{"file" => %{"old_content" => old, "new_content" => new, "read_errors" => []}} =
             svelte_props(render(view), "DiffViewer-0")

    assert old =~ "fn original() {}"
    assert new =~ "fn renamed_fn() {}"
  end

  test "binary files get a header but no full-file link or rendered-markdown toggle", %{
    conn: conn
  } do
    repo = tmp_git_repo()
    stage(repo, ".gitattributes", "added.md -diff\n")
    stage(repo, "BUILD.bazel", <<0, 255, 1>>)
    commit(repo, "base")
    stage(repo, "BUILD.bazel", <<0, 254, 2>>)
    stage(repo, "added.md", "# Binary by attributes\n")
    stage(repo, "README.md", "# Text\n")
    {:ok, state} = ReviewState.from_target({:staged, nil}, repo)
    section = fn name -> "#file-#{Enum.find_index(state.files, &(&1.file_name == name))}" end

    view = mount_unbound(conn, state)

    assert has_element?(view, "#{section.("BUILD.bazel")} button.file-row", ~r/▾\s*M\s*BUILD/)
    refute has_element?(view, "#{section.("BUILD.bazel")} a.view-file")
    assert has_element?(view, "#{section.("added.md")} button.file-row", ~r/▾\s*A\s*added\.md/)
    refute has_element?(view, "#{section.("added.md")} a.view-file")
    refute has_element?(view, "#{section.("added.md")} .md-view-toggle")

    # A text markdown file keeps both.
    assert has_element?(view, "#{section.("README.md")} a.view-file[aria-label='Open full file']")
    assert has_element?(view, "#{section.("README.md")} .md-view-toggle")
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
    refute_push_event(view, "drafts:wipe", _, 0)
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
      global_comments: [
        %{
          id: "g1",
          body: "just a follow-up",
          finding_type: :follow_up,
          correct_instructions: false,
          lint_rule: false
        }
      ]
    }

    put_state(state)
    {:ok, view, _html} = live_isolated(conn, ReviewLive)

    assert has_element?(view, "button.approve-btn", ~r/^\s*Approve with feedback\s*$/)
    refute has_element?(view, "button.reject-btn[disabled]")

    html = view |> element("button.approve-btn") |> render_click()
    assert html =~ "Approved"

    assert {:approve_with_feedback, payload} = Decision.current()
    assert payload =~ "just a follow-up"
  end

  test "reject renders the Feedback-sent done view", %{conn: conn} do
    view = mount_unbound(conn)
    html = render_click(view, "decision.reject", %{})
    assert html =~ "Feedback sent"
  end

  test "a decision in one tab puts every other open tab on the done view", %{conn: conn} do
    view = mount_unbound(conn)
    {:ok, other, _html} = live_isolated(conn, ReviewLive)
    assert has_element?(other, "button.reject-btn")

    render_click(view, "decision.reject", %{})

    assert render(other) =~ "Feedback sent"
    refute has_element?(other, "button.reject-btn")
  end

  test "a decision made outside any tab puts open tabs on the done view and wipes drafts",
       %{conn: conn} do
    repo = tmp_git_repo()
    on_exit(fn -> File.rm_rf!(repo) end)
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    {:ok, _} = Decision.submit({:timeout, ""})

    assert render(view) =~ "Approved"
    assert_push_event(view, "drafts:wipe", %{review_id: ^rid})
  end

  test "a tab that mounts after a decision it missed opens on the done view and wipes drafts",
       %{conn: conn} do
    repo = tmp_git_repo()
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, _} = Decision.submit({:timeout, ""})

    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    assert render(view) =~ "Approved"
    assert_push_event(view, "drafts:wipe", %{review_id: ^rid})
  end

  test "a tab that mounts before any decision keeps its drafts", %{conn: conn} do
    repo = tmp_git_repo()
    on_exit(fn -> File.rm_rf!(repo) end)

    {view, _rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    refute_push_event(view, "drafts:wipe", _, 0)
  end

  test "an open comment form disables Approve and Send Feedback until it closes", %{conn: conn} do
    view = mount_unbound(conn)

    # With no comments: a bare Approve, and nothing to send as feedback.
    assert has_element?(view, "button.approve-btn", ~r/^\s*Approve\s*$/)
    refute has_element?(view, "button.approve-btn[disabled]")
    assert has_element?(view, "button.reject-btn[disabled]")

    view |> element("button.add-global-btn") |> render_click()
    assert has_element?(view, "button.approve-btn[disabled]")
    assert has_element?(view, "button.reject-btn[disabled]")

    # CommentForm's Cancel.
    render_hook(view, "comment_form.hide", %{"form_key" => "global"})
    refute has_element?(view, "button.approve-btn[disabled]")
  end

  test "Cancel wipes the review's comments and submits an empty cancel", %{conn: conn} do
    repo = tmp_git_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)
    add_global_comment(view, "wipe me")
    assert [_] = ReviewServer.get_state(rid).global_comments

    html = view |> element("button.cancel-btn") |> render_click()

    assert html =~ "Cancelled"
    assert Decision.current() == {:cancel, ""}
    assert ReviewServer.get_state(rid).global_comments == []
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

  test "Post to GitHub sends the comments through gh api and opens the returned review", %{
    conn: conn
  } do
    repo = tmp_git_repo()
    pr_url = "https://github.com/example/example/pull/456"
    review_url = pr_url <> "#pullrequestreview-12345"

    # gh is GitHub's boundary: the stub keeps the `--input` request body
    # and answers with a pending review, as `gh api` does.
    stub_dir = Path.join(repo, "gh-stub")
    captured = Path.join(stub_dir, "last-api-input.json")
    File.mkdir_p!(stub_dir)

    File.write!(Path.join(stub_dir, "gh"), """
    #!/bin/sh
    [ "$1" = "api" ] || exit 1
    while [ "$#" -gt 0 ]; do
      [ "$1" = "--input" ] && cp "$2" '#{captured}'
      shift
    done
    echo '{"id":12345,"html_url":"#{review_url}","state":"PENDING"}'
    """)

    File.chmod!(Path.join(stub_dir, "gh"), 0o755)
    prev_path = System.fetch_env!("PATH")
    System.put_env("PATH", stub_dir <> ":" <> prev_path)
    on_exit(fn -> System.put_env("PATH", prev_path) end)

    state = %ReviewState{
      files: [@plain_file],
      pr: %{number: 456, title: "Feature: add a thing", url: pr_url}
    }

    {view, _rid} = mount_bound(conn, state, repo)
    add_global_comment(view, "looks good overall, one nit", "follow_up")

    view |> element("button[phx-click='decision.post_to_github']") |> render_click()

    assert_push_event(view, "open-url", %{url: ^review_url})
    request = captured |> File.read!() |> Jason.decode!()
    assert request["event"] == "PENDING"
    assert request["body"] =~ "looks good overall, one nit"
  end
end
