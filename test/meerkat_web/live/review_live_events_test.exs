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
  #   `pending_answers_banner`, `version_chip`, `commit_message_section`,
  #   `global_comments_section`,
  #   `file_list`, `markdown_preview`, `file_filter`, and `diff_toolbar` —
  #   deleting an `attr` line removes compile-time validation metadata
  #   only; with every call site passing its assigns, no runtime behaviour
  #   differs. `markdown_preview`'s `:read_errors` attr default is never
  #   used because its only caller always passes `read_errors`.

  use MeerkatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Meerkat.{ApprovalCache, Decision, PendingAnswers, ReviewServer, ReviewState}
  alias MeerkatWeb.ReviewLive
  import Meerkat.TestHelpers, only: [make_git_repo: 1, git: 2, isolate_git_config: 0, stage: 3]

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

  # Subject at L1, a two-line body at L3-4, list items at L6 and L7.
  @commit_msg """
  Subject line under sixty-three chars

  Body paragraph that explains the why.
  Multiple lines so the gutter has a multi-line block.

  - bullet one
  - bullet two
  """

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
        assert_push_event(view, ^event, %{})
        true
      rescue
        ExUnit.AssertionError -> false
        ArgumentError -> false
      end

    refute pushed, "expected no #{event} push"
  end

  # Commit in a fixture repo; call isolate_git_config/0 first so the
  # user's hooks and signing config stay out of it.
  defp commit(repo, message) do
    git(repo, [
      "-c",
      "user.email=t@t",
      "-c",
      "user.name=t",
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      message
    ])
  end

  defp count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  # The props a LiveSvelte mount point hands its Svelte component, read
  # from `html`, the render that mounted it. Later renders carry only
  # the props that changed, so after a bound review's ReviewServer
  # broadcast re-renders the page, `data-props` is `{}`.
  defp svelte_props(html, id) do
    [json] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query_by_id(id)
      |> LazyHTML.attribute("data-props")

    Jason.decode!(json)
  end

  # The event CommentForm.svelte pushes when the submit button of the
  # form keyed `form_key` is pressed.
  defp submit_comment(view, form_key, body, finding_type \\ "issue") do
    render_hook(view, "comment.submit", %{
      "form_key" => form_key,
      "body" => body,
      "finding_type" => finding_type,
      "learn_from_this" => false
    })
  end

  # "+ Add global comment" or "+ Add another", whichever is showing.
  defp add_global_comment(view, body, finding_type \\ "issue") do
    view |> element("button[phx-click='comment_form.show_global']") |> render_click()
    submit_comment(view, "global", body, finding_type)
  end

  # The DOM id of the form keyed `form_key`, as `ReviewLive` renders it.
  defp form_id(form_key), do: "CommentForm-" <> String.replace(form_key, ~r/[^A-Za-z0-9_-]/, "-")

  defp open_files_panel(view) do
    view |> element("button.toolbar-icon-btn", "Files") |> render_click()
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

  test "the Wrap toggle starts checked and unchecks on click", %{conn: conn} do
    view = mount_unbound(conn)
    assert has_element?(view, ".wrap-toggle input[checked]")

    view |> element(".wrap-toggle input") |> render_click()
    refute has_element?(view, ".wrap-toggle input[checked]")
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
      Path.join(System.tmp_dir!(), "meerkat-lv-release-#{System.unique_integer([:positive])}")

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

  ## --- Page ---

  test "a staged review renders its file rows, commit-message gutter and decision buttons", %{
    conn: conn
  } do
    isolate_git_config()
    repo = tmp_git_repo()
    commit(repo, "init")
    stage(repo, "NOTES.md", "# Notes\n")
    stage(repo, "src/main.rs", "fn main() {}\n")
    msg_path = Path.join(repo, "COMMIT_EDITMSG")
    File.write!(msg_path, @commit_msg)
    {:ok, state} = ReviewState.from_target({:staged, msg_path}, repo)
    view = mount_unbound(conn, state)

    assert has_element?(view, "button.file-row", ~r/^\s*▾\s*A\s*NOTES\.md\s*$/)
    assert has_element?(view, "button.file-row", ~r/^\s*▾\s*A\s*src\/main\.rs\s*$/)

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
    isolate_git_config()
    repo = tmp_git_repo()
    stage(repo, "base.txt", "base\n")
    commit(repo, "Base")
    stage(repo, "added-by-feature.rs", "fn feature() {}\n")
    commit(repo, "Add feature module")

    {:ok, state} = ReviewState.from_target({:single_ref, "HEAD"}, repo)
    view = mount_unbound(conn, state)

    assert has_element?(view, "button.file-row", ~r/^\s*▾\s*A\s*added-by-feature\.rs\s*$/)
    refute has_element?(view, "button.file-row", "base.txt")

    assert has_element?(
             view,
             "button.gutter-line-num[aria-label='Comment on commit message line 1']"
           )
  end

  test "a two-dot range review shows only the files changed between the refs", %{conn: conn} do
    isolate_git_config()
    repo = tmp_git_repo()
    stage(repo, "first.txt", "first commit body\n")
    commit(repo, "First commit")
    stage(repo, "second.txt", "second commit body\n")
    commit(repo, "Second commit")

    {:ok, state} = ReviewState.from_target({:range, "HEAD~1", "HEAD", :two_dot}, repo)
    view = mount_unbound(conn, state)

    assert has_element?(view, "button.file-row", ~r/^\s*▾\s*A\s*second\.txt\s*$/)
    refute has_element?(view, "button.file-row", "first.txt")
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
    isolate_git_config()
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
    isolate_git_config()
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
      global_comments: [
        %{id: "g1", body: "just a follow-up", finding_type: :follow_up, learn_from_this: false}
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

  test "revealing a form on a file already shown pins no :show override", %{conn: conn} do
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, tmp_git_repo())

    render_hook(view, "comment_form.show_file", %{"file_index" => "0"})
    render_click(view, "comment_form.reveal", %{"form_key" => "file:0"})

    assert has_element?(view, "#file-0")
    assert ReviewServer.get_state(rid).file_overrides == %{}
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

  ## --- Comments ---

  test "a global comment is added, edited through a Save form, and removed", %{conn: conn} do
    repo = tmp_git_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    add_global_comment(view, "first version")
    assert has_element?(view, ".global-comments .note", "first version")

    # Submitting closes the form for good: a fresh tab doesn't reopen it.
    assert ReviewServer.get_state(rid).open_forms == []
    refute has_element?(view, "#CommentForm-global")
    {:ok, fresh, _html} = live_isolated(conn, ReviewLive)
    refute has_element?(fresh, "#CommentForm-global")

    html = view |> element(".global-comments .note button", "Edit") |> render_click()
    [%{id: id}] = ReviewServer.get_state(rid).global_comments
    edit_key = "global:edit:#{id}"

    assert %{"submitLabel" => "Save", "initialBody" => "first version"} =
             svelte_props(html, form_id(edit_key))

    submit_comment(view, edit_key, "second version")
    assert has_element?(view, ".global-comments .note", "second version")
    refute has_element?(view, ".global-comments .note", "first version")
    assert count(view, ".global-comments .note") == 1

    view |> element(".global-comments .note button", "Remove") |> render_click()
    assert count(view, ".global-comments .note") == 0
  end

  test "each finding type renders its own card class and badge label", %{conn: conn} do
    repo = tmp_git_repo()
    {view, _rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    types = [
      {"issue", "issue"},
      {"follow_up", "follow-up"},
      {"question", "question"},
      {"suggestion", "suggestion"}
    ]

    for {type, _label} <- types, do: add_global_comment(view, "body for #{type}", type)

    for {type, label} <- types do
      card = ".global-comments .note.note-#{type}"
      assert has_element?(view, card, "body for #{type}")
      assert has_element?(view, "#{card} .finding-badge", ~r/^\s*#{label}\s*$/)
    end
  end

  test "a file comment is added from the file's button, edited, and removed", %{conn: conn} do
    repo = tmp_git_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)
    body = "#file-0 .note.file-note .comment-body"

    html = view |> element("#file-0 button", "+ Add file comment") |> render_click()
    assert %{"submitLabel" => "Add File Comment"} = svelte_props(html, "CommentForm-file-0")

    submit_comment(view, "file:0", "file-level concern", "question")
    assert has_element?(view, body, ~r/^\s*file-level concern\s*$/)
    assert [%{file_index: 0, id: id}] = ReviewServer.get_state(rid).file_comments
    edit_key = "file:0:edit:#{id}"

    html = view |> element("#file-0 .note.file-note button", "Edit") |> render_click()

    assert %{
             "submitLabel" => "Save",
             "initialBody" => "file-level concern",
             "initialFindingType" => "question"
           } = svelte_props(html, form_id(edit_key))

    submit_comment(view, edit_key, "file-level concern v2", "question")
    assert has_element?(view, body, ~r/^\s*file-level concern v2\s*$/)
    assert count(view, "#file-0 .note.file-note") == 1

    view |> element("#file-0 .note.file-note button", "Remove") |> render_click()
    assert count(view, "#file-0 .note.file-note") == 0
  end

  test "opening then cancelling a file-comment form keeps the other comments", %{conn: conn} do
    repo = tmp_git_repo()
    {view, _rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

    add_global_comment(view, "global baseline")
    view |> element("#file-0 button", "+ Add file comment") |> render_click()
    submit_comment(view, "file:0", "file baseline")

    for _ <- 1..3 do
      view |> element("#file-0 button", "+ Add file comment") |> render_click()
      assert has_element?(view, "#CommentForm-file-0")
      # CommentForm's Cancel.
      render_hook(view, "comment_form.hide", %{"form_key" => "file:0"})
      refute has_element?(view, "#CommentForm-file-0")
    end

    assert has_element?(view, ".global-comments .note", "global baseline")
    assert has_element?(view, "#file-0 .note.file-note", "file baseline")
  end

  test "commit-message comments land in the gutter with their line range", %{conn: conn} do
    repo = tmp_git_repo()
    msg = String.trim(@commit_msg)

    state = %ReviewState{
      files: [@plain_file],
      commit_message: msg,
      commit_message_blocks: ReviewState.blocks(msg)
    }

    {view, _rid} = mount_bound(conn, state, repo)

    html =
      view
      |> element("button.gutter-line-num[aria-label='Comment on commit message line 1']")
      |> render_click()

    assert %{"submitLabel" => "Add Commit Message Comment"} =
             svelte_props(html, "CommentForm-commit_msg-1-1")

    submit_comment(view, "commit_msg:1-1", "subject too vague")

    # A drag across the L1 and L3-4 blocks; the CommitMsgGutter hook sends the span.
    render_hook(view, "comment_form.show_commit_msg", %{"start_line" => "1", "end_line" => "4"})
    submit_comment(view, "commit_msg:1-4", "subject + body together")

    assert has_element?(view, ".commit-msg-note", ~r/L1–1.*subject too vague/s)
    assert has_element?(view, ".commit-msg-note", ~r/L1–4.*subject \+ body together/s)
    refute has_element?(view, "[id^='CommentForm-commit_msg']")
  end

  test "learn-from-this starts off in the form and toggles on the rendered comment", %{
    conn: conn
  } do
    repo = tmp_git_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)
    learn = ".global-comments .note .learn-toggle input"

    html = view |> element("button.add-global-btn") |> render_click()
    assert %{"initialLearnFromThis" => false} = svelte_props(html, "CommentForm-global")
    submit_comment(view, "global", "learn me")
    refute has_element?(view, "#{learn}[checked]")

    view |> element(learn) |> render_click()
    assert [%{learn_from_this: true}] = ReviewServer.get_state(rid).global_comments
    assert has_element?(view, "#{learn}[checked]")

    view |> element(learn) |> render_click()
    assert [%{learn_from_this: false}] = ReviewServer.get_state(rid).global_comments
    refute has_element?(view, "#{learn}[checked]")
  end

  test "a comment added or removed in one tab updates another tab of the same review", %{
    conn: conn
  } do
    repo = tmp_git_repo()
    {tab_a, _rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)
    {:ok, tab_b, _html} = live_isolated(conn, ReviewLive)

    add_global_comment(tab_a, "from tab A")
    assert has_element?(tab_b, ".global-comments .note", "from tab A")

    tab_a |> element(".global-comments .note button", "Remove") |> render_click()
    refute has_element?(tab_b, ".global-comments .note")
  end

  test "a comment body's <script> renders as text, not an element", %{conn: conn} do
    body = "hello <script>alert(1)</script> world"

    view =
      mount_unbound(conn, %ReviewState{
        files: [@plain_file],
        global_comments: [%{id: "g1", body: body, finding_type: :issue, learn_from_this: false}]
      })

    card = view |> element(".global-comments .note") |> render()
    assert card =~ "hello"
    assert card =~ "world"
    refute card =~ ~r/<script/i
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

  test "an approved staged deletion stays approved in the next review round", %{conn: conn} do
    isolate_git_config()
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

    view |> element(".file-filter button", "Show all") |> render_click()
    assert has_element?(view, ".file-list .file-name", "src/widget.rs")
    refute has_element?(view, ".file-filter button", "Show all")
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
    isolate_git_config()
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
    isolate_git_config()
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
    no_push_event(view, "scroll-into-view")
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
