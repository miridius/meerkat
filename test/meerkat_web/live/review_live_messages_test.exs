defmodule MeerkatWeb.ReviewLiveMessagesTest do
  # What `MeerkatWeb.ReviewLive` tells the reviewer and the operator: its
  # stderr breadcrumbs, error banners and done headings, and the PubSub
  # and app-env inputs it reacts to. `MeerkatWeb.ReviewLiveEventsCase`
  # describes the setup.

  use MeerkatWeb.ReviewLiveEventsCase

  import ExUnit.CaptureIO, only: [capture_io: 2]

  alias Meerkat.{Decision, PendingAnswers, ReviewServer, ReviewState}

  @plain_file plain_file()

  describe "MeerkatWeb.ReviewLive's stderr breadcrumbs" do
    test "a non-integer index or size is logged with its event and field, and changes nothing",
         %{conn: conn} do
      state = %ReviewState{
        files: [@plain_file],
        commit_message: "subject",
        commit_message_blocks: [%{start_line: 1, end_line: 1, text: "subject"}]
      }

      view = mount_unbound(conn, state)

      logged = fn event, payload ->
        capture_io(:stderr, fn -> render_hook(view, event, payload) end)
      end

      assert logged.("toolbar.set_font_size", %{"px" => "junk"}) ==
               ~s(meerkat: toolbar.set_font_size ignored — non-integer px: "junk"\n)

      assert logged.("toolbar.bump_font_size", %{"by" => "junk"}) ==
               ~s(meerkat: toolbar.bump_font_size ignored — non-integer by: "junk"\n)

      assert logged.("toolbar.set_tab_size", %{"n" => "junk"}) ==
               ~s(meerkat: toolbar.set_tab_size ignored — non-integer n: "junk"\n)

      assert logged.("comment_form.show_file", %{"file_index" => "x"}) ==
               ~s(meerkat: comment_form.show_file ignored — non-integer file_index: "x"\n)

      assert logged.("comment_form.show_commit_msg", %{"start_line" => "a", "end_line" => "1"}) ==
               ~s(meerkat: comment_form.show_commit_msg ignored — non-integer start_line/end_line: {"a", "1"}\n)

      line = %{"file_index" => "0", "start_line" => "1", "end_line" => "b", "side" => "new"}

      assert logged.("comment_form.show_at_line", line) ==
               ~s(meerkat: comment_form.show_at_line ignored — non-integer file_index/start_line/end_line: {"0", "1", "b"}\n)

      assert logged.("filter.show_only", %{"file_index" => "x"}) ==
               ~s(meerkat: filter.show_only ignored — non-integer file_index: "x"\n)

      refute has_element?(view, ".dirty-form-link")
      assert saved_settings_or_none() == %{}
    end

    test "closing a form without a string key is logged and closes nothing; its key closes it",
         %{conn: conn} do
      view = mount_unbound(conn)
      render_click(view, "comment_form.show_global", %{})

      stderr =
        capture_io(:stderr, fn -> render_hook(view, "comment_form.hide", %{"form_key" => 5}) end)

      assert stderr == ~s(meerkat: comment_form.hide ignored — no form_key: %{"form_key" => 5}\n)
      assert has_element?(view, ".dirty-form-link")

      render_hook(view, "comment_form.hide", %{"form_key" => "global"})
      refute has_element?(view, ".dirty-form-link")
    end

    test "a submit from a form that is no longer open is logged with its key", %{conn: conn} do
      view = mount_unbound(conn)

      stderr = capture_io(:stderr, fn -> submit_comment(view, "global", "x") end)

      assert stderr == ~s(meerkat: comment.submit ignored — form not open: "global"\n)
    end
  end

  describe "MeerkatWeb.ReviewLive's error banners" do
    test "an approval with no blob id is logged, and flashed as not kept for next time",
         %{conn: conn} do
      repo = state_repo()
      Application.put_env(:meerkat, :repo_path, repo)

      view =
        mount_unbound(conn, %ReviewState{
          files: [%{@plain_file | effective_oid: nil}],
          approval_key: "main"
        })

      stderr =
        capture_io(:stderr, fn ->
          render_hook(view, "file.toggle_approved", %{"file_name" => "src/widget.rs"})
        end)

      assert stderr ==
               "meerkat: approval for src/widget.rs not persisted to cache: no effective_oid " <>
                 "(staged-blob lookup failed at mount, or file not in state)\n"

      assert flash_text(view) ==
               "Approval tick for src/widget.rs didn't persist (:missing_oid). " <>
                 "Re-tick next session if you want it cached."
    end

    test "a failed post to GitHub is logged and flashed with gh's reason", %{conn: conn} do
      state = %ReviewState{files: [@plain_file], pr: %{number: 7, title: "t", url: "u"}}
      {view, _rid} = mount_bound(conn, state, state_repo())
      Meerkat.TestHelpers.put_env("PATH", "/nonexistent")

      stderr =
        capture_io(:stderr, fn -> render_click(view, "decision.post_to_github", %{}) end)

      assert stderr == "meerkat: gh api failed — gh binary not found on PATH\n"
      assert flash_text(view) == "Couldn't post review to GitHub: gh binary not found on PATH"
    end

    test "a post to GitHub without a PR says so", %{conn: conn} do
      view = mount_unbound(conn, %ReviewState{files: [@plain_file], pr: nil})
      render_click(view, "decision.post_to_github", %{})
      assert flash_text(view) == "No PR attached to this review — can't post to GitHub."
    end

    test "comments that stop saving to disk raise a banner naming the reason", %{conn: conn} do
      view = mount_unbound(conn)
      send(view.pid, {:persistence_failed, :eacces})

      assert flash_text(view) ==
               "Comments aren't being saved to disk (:eacces). Copy any in-progress text " <>
                 "before closing the tab; resolve the underlying issue and re-tick."
    end
  end

  describe "MeerkatWeb.ReviewLive's decisions" do
    # Not make_state_repo: its cached meerkat dir serves every repo path,
    # so the cwd's answers file would be this repo's too.
    defp repo_with_pending_answers do
      repo = Meerkat.TestHelpers.make_tmp_repo("meerkat-lv")
      on_exit(fn -> File.rm_rf!(repo) end)
      put_pending_answers(repo)
      Application.put_env(:meerkat, :repo_path, repo)
      repo
    end

    defp put_pending_answers(repo) do
      Meerkat.TestHelpers.put_pending_answers(repo, [
        %{location: "f.ex:1", question: "q", answer: "a"}
      ])

      assert PendingAnswers.load(repo)
    end

    test "Send Feedback shows its done heading and clears pending answers", %{conn: conn} do
      repo = repo_with_pending_answers()
      view = mount_unbound(conn)

      render_click(view, "decision.reject", %{})

      assert has_element?(view, "h1", ~r/^Feedback sent$/)
      refute PendingAnswers.load(repo)
    end

    test "Cancel shows its done heading and clears pending answers", %{conn: conn} do
      repo = repo_with_pending_answers()
      view = mount_unbound(conn)

      render_click(view, "decision.cancel", %{})

      assert has_element?(view, "h1", ~r/^Cancelled$/)
      assert Decision.current() == {:cancel, ""}
      refute PendingAnswers.load(repo)
    end
  end

  describe "MeerkatWeb.ReviewLive's PubSub and app env" do
    test "a newly installed version live-restarts an idle tab", %{conn: conn} do
      _view = mount_unbound(conn)

      Phoenix.PubSub.broadcast(
        Meerkat.PubSub,
        Meerkat.VersionWatcher.topic(),
        {:meerkat_version_available, "versions/v2"}
      )

      assert_receive {:restart, 75}
    end

    test "the countdown shows the review's deadline, set at mount or later", %{conn: conn} do
      prev = Application.fetch_env(:meerkat, :review_deadline_ms)

      on_exit(fn ->
        case prev do
          {:ok, v} -> Application.put_env(:meerkat, :review_deadline_ms, v)
          :error -> Application.delete_env(:meerkat, :review_deadline_ms)
        end
      end)

      Application.put_env(:meerkat, :review_deadline_ms, 4_102_444_800_000)
      view = mount_unbound(conn)
      assert has_element?(view, "#review-countdown[data-deadline='4102444800000']")

      Phoenix.PubSub.broadcast(
        Meerkat.PubSub,
        Decision.deadline_topic(),
        {:meerkat_deadline, 4_102_444_900_000}
      )

      assert has_element?(view, "#review-countdown[data-deadline='4102444900000']")
    end

    test "the page before LiveView connects is titled, and hears none of the review's changes",
         %{conn: conn} do
      put_test_vite_manifest()
      rid = "lvtest-#{System.unique_integer([:positive])}"
      Application.put_env(:meerkat, :review_id, rid)
      Application.put_env(:meerkat, :repo_path, state_repo())
      Application.put_env(:meerkat, :review_state, %ReviewState{files: [@plain_file]})

      html = conn |> get("/") |> html_response(200)
      assert html =~ ~r/<title[^>]*>\s*meerkat commit review\s*<\/title>/

      ReviewServer.set_show_generated(rid, true)
      refute_received {:state_changed, _}
    end
  end

  describe "MeerkatWeb.ReviewLive's page furniture" do
    test "the footer counts no comments as 0, and the toolbar shows the connection", %{conn: conn} do
      view = mount_unbound(conn)
      assert has_element?(view, ".comment-count", ~r/^\s*0 comments\s*$/)
      assert has_element?(view, ".conn-indicator .conn-label-connected", "connected")
    end

    test "Split switches back from Unified", %{conn: conn} do
      view = mount_unbound(conn)
      render_click(view, "set_diff_mode", %{"mode" => "unified"})
      render_click(view, "set_diff_mode", %{"mode" => "split"})
      assert saved_settings() == %{"diff_mode" => "split"}
    end

    @tag :capture_log
    test "an unknown diff mode is refused and not saved", %{conn: conn} do
      view = mount_unbound(conn)
      Process.flag(:trap_exit, true)

      catch_exit(render_click(view, "set_diff_mode", %{"mode" => "sideways"}))

      assert saved_settings_or_none() == %{}
    end

    @tag :capture_log
    test "a line form on an unknown side is refused", %{conn: conn} do
      {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, state_repo())
      Process.flag(:trap_exit, true)
      line = %{"file_index" => "0", "start_line" => "1", "end_line" => "1", "side" => "middle"}

      catch_exit(render_hook(view, "comment_form.show_at_line", line))

      assert ReviewServer.get_state(rid).open_forms == []
    end

    defp saved_settings_or_none do
      if File.exists?(Meerkat.Settings.path()), do: saved_settings(), else: %{}
    end
  end
end
