defmodule MeerkatWeb.ReviewLiveWiringTest do
  # How `MeerkatWeb.ReviewLive`'s events reach the ReviewServer, the
  # approval cache and the props each comment form mounts with, and how
  # showing a file lifts the filters that hide it.
  # `MeerkatWeb.ReviewLiveEventsCase` describes the setup.

  use MeerkatWeb.ReviewLiveEventsCase

  alias Meerkat.{ApprovalCache, OpenForms, ReviewServer, ReviewState}

  @plain_file plain_file()
  @md_file md_file()

  @comment %{
    body: "note",
    finding_type: :issue,
    correct_instructions: false,
    lint_rule: false,
    created_at: "2026-01-01T00:00:00Z"
  }

  describe "MeerkatWeb.ReviewLive's review server writes" do
    test "an unbound review's comment, filter and cancel events need no review server",
         %{conn: conn} do
      state = %ReviewState{
        files: [@plain_file, %{@md_file | file_name: "notes.md"}],
        hidden_extensions: MapSet.new(["md"]),
        global_comments: [Map.put(@comment, :id, "g1")]
      }

      view = mount_unbound(conn, state)
      flag = %{"surface" => "global", "id" => "g1", "flag" => "lint_rule", "checked" => "true"}
      render_click(view, "comment.toggle_flag", flag)
      render_click(view, "comment.remove", %{"surface" => "global", "id" => "g1"})
      render_click(view, "filter.toggle_extension", %{"ext" => "md"})
      # Hides a shown file, then shows a hidden one.
      render_click(view, "filter.toggle_file", %{"file_name" => "src/widget.rs"})
      render_click(view, "filter.toggle_file", %{"file_name" => "notes.md"})
      render_click(view, "filter.hide_matched", %{})
      render_click(view, "filter.show_matched", %{})
      render_click(view, "filter.toggle_generated", %{})

      # With nothing to write them to, none of them changes the page.
      assert has_element?(view, ".global-comments .comment-body", "note")
      assert has_element?(view, "#file-0")
      refute has_element?(view, "#file-1")

      render_click(view, "decision.cancel", %{})
      assert has_element?(view, "h1", ~r/^Cancelled$/)
    end

    test "Show all clears the review's saved file overrides", %{conn: conn} do
      state = %ReviewState{files: [@plain_file], file_overrides: %{"src/widget.rs" => :hide}}
      {view, rid} = mount_bound(conn, state, state_repo())

      render_click(view, "filter.show_all", %{})

      assert ReviewServer.get_state(rid).file_overrides == %{}
    end

    test "bulk hide and show overwrite the matched files' overrides", %{conn: conn} do
      other = %{@plain_file | file_name: "other.ex"}

      state = %ReviewState{
        files: [@plain_file, other],
        file_overrides: %{"src/widget.rs" => :show}
      }

      {view, rid} = mount_bound(conn, state, state_repo())

      render_click(view, "filter.hide_matched", %{})
      hidden = %{"src/widget.rs" => :hide, "other.ex" => :hide}
      assert ReviewServer.get_state(rid).file_overrides == hidden

      render_click(view, "filter.show_matched", %{})
      shown = %{"src/widget.rs" => :show, "other.ex" => :show}
      assert ReviewServer.get_state(rid).file_overrides == shown
    end

    test "un-approving a file drops only its cached approval", %{conn: conn} do
      repo = state_repo()

      {:ok, _} =
        ApprovalCache.modify(ApprovalCache.path_for(repo), fn cache ->
          cache
          |> ApprovalCache.approve("main", "src/widget.rs", "oid1")
          |> ApprovalCache.approve("main", "other.rs", "oid2")
        end)

      Application.put_env(:meerkat, :repo_path, repo)

      view =
        mount_unbound(conn, %ReviewState{
          files: [%{@plain_file | effective_oid: "oid1"}],
          approval_key: "main",
          approved_file_names: MapSet.new(["src/widget.rs"])
        })

      render_hook(view, "file.toggle_approved", %{"file_name" => "src/widget.rs"})

      refute has_element?(view, "[data-test=flash-error]")
      cache = ApprovalCache.load_for(repo)
      refute ApprovalCache.approved?(cache, "main", "src/widget.rs", "oid1")
      assert ApprovalCache.approved?(cache, "main", "other.rs", "oid2")
    end
  end

  describe "MeerkatWeb.ReviewLive's comment form props" do
    test "a global form mounts with its key, label and draft key, and Save when editing",
         %{conn: conn} do
      state = %ReviewState{files: [@plain_file], global_comments: [Map.put(@comment, :id, "g1")]}
      view = mount_unbound(conn, state)

      html = render_click(view, "comment_form.show_global", %{})

      assert %{
               "formKey" => "global",
               "submitLabel" => "Add Global Comment",
               "draftKey" => "meerkat:draft:unbound:global",
               "initialBody" => "",
               "initialFindingType" => "issue"
             } = svelte_props(html, "CommentForm-global")

      html = render_click(view, "comment_form.edit", %{"surface" => "global", "id" => "g1"})
      assert %{"submitLabel" => "Save"} = svelte_props(html, form_id("global:edit:g1"))
      assert has_element?(view, ".dirty-form-link", ~r/^\s*Global \(editing\)\s*$/)
    end

    test "a file form mounts with its draft key", %{conn: conn} do
      view = mount_unbound(conn)
      html = render_click(view, "comment_form.show_file", %{"file_index" => "0"})

      assert %{"draftKey" => "meerkat:draft:unbound:file:0"} =
               svelte_props(html, "CommentForm-file-0")
    end

    test "a commit-message form mounts seeded with its lines, and Save when editing",
         %{conn: conn} do
      comment = Map.merge(@comment, %{id: "c1", start_line: 1, end_line: 1})

      state = %ReviewState{
        files: [@plain_file],
        commit_message: "subject\n\nbody",
        commit_message_blocks: ReviewState.blocks("subject\n\nbody"),
        commit_message_comments: [comment]
      }

      view = mount_unbound(conn, state)
      lines = %{"start_line" => "1", "end_line" => "1"}
      html = render_hook(view, "comment_form.show_commit_msg", lines)

      assert %{
               "submitLabel" => "Add Commit Message Comment",
               "draftKey" => "meerkat:draft:unbound:commit_msg:1-1",
               "initialCode" => "subject"
             } = svelte_props(html, "CommentForm-commit_msg-1-1")

      html = render_click(view, "comment_form.edit", %{"surface" => "commit_msg", "id" => "c1"})
      assert %{"submitLabel" => "Save"} = svelte_props(html, form_id("commit_msg:1-1:edit:c1"))
    end

    test "a line form reaches its file's DiffViewer keyed, labelled and with its draft key, and Save when editing",
         %{conn: conn} do
      comment =
        Map.merge(@comment, %{id: "i1", file_index: 0, start_line: 1, end_line: 1, side: "new"})

      view = mount_unbound(conn, %ReviewState{files: [@plain_file], comments: [comment]})
      line = %{"file_index" => "0", "start_line" => "1", "end_line" => "1", "side" => "new"}
      html = render_hook(view, "comment_form.show_at_line", line)

      assert %{"inline_forms" => [%{"key" => "inline:0:new:1-1", "props" => props}]} =
               svelte_props(html, "DiffViewer-0")

      assert %{
               "submitLabel" => "Add Comment",
               "draftKey" => "meerkat:draft:unbound:inline:0:new:1-1"
             } = props

      html = render_click(view, "comment_form.edit", %{"surface" => "inline", "id" => "i1"})
      %{"inline_forms" => forms} = svelte_props(html, "DiffViewer-0")
      edit = Enum.find(forms, &(&1["key"] == "inline:0:new:1-1:edit:i1"))
      assert %{"props" => %{"submitLabel" => "Save"}} = edit
    end
  end

  describe "MeerkatWeb.ReviewLive's showing a hidden file" do
    defp jump_to(view, name) do
      target = %{"file_name" => name, "side" => "new", "line_start" => 1, "line_end" => 1}
      render_click(view, "moved.jump", target)
    end

    @files [@plain_file, %{@md_file | file_name: "a.md"}]

    test "showing a file overrides its saved hide", %{conn: conn} do
      view = mount_unbound(conn, %ReviewState{files: @files, file_overrides: %{"a.md" => :hide}})
      jump_to(view, "a.md")
      assert has_element?(view, "#file-1")
    end

    test "showing a file hidden by type keeps show-only on it, and a filter it matches",
         %{conn: conn} do
      state = %ReviewState{files: @files, hidden_extensions: MapSet.new(["md"])}

      view = mount_unbound(conn, state)
      render_hook(view, "filter.show_only", %{"file_index" => "1"})
      jump_to(view, "a.md")
      assert has_element?(view, "#file-1")
      refute has_element?(view, "#file-0")

      view = mount_unbound(conn, state)
      render_hook(view, "filter.set_input", %{"value" => "a"})
      jump_to(view, "a.md")
      assert has_element?(view, "#file-1")
      refute has_element?(view, "#file-0")
    end

    test "revealing a global form shows no file", %{conn: conn} do
      form = %{surface: :global, anchor: %{file_index: 1}}

      state = %ReviewState{
        files: @files,
        hidden_extensions: MapSet.new(["md"]),
        open_forms: [form]
      }

      view = mount_unbound(conn, state)
      render_hook(view, "comment_form.reveal", %{"form_key" => OpenForms.key(form)})
      refute has_element?(view, "#file-1")
    end
  end

  describe "MeerkatWeb.ReviewLive's rendering" do
    test "the rendered view of an added or deleted markdown file marks all its blocks changed",
         %{conn: conn} do
      added = %{
        @md_file
        | file_name: "a.md",
          status: :added,
          old_content: nil,
          new_content: "x\n"
      }

      deleted = %{
        @md_file
        | file_name: "d.md",
          status: :deleted,
          old_content: "x\n",
          new_content: nil
      }

      view = mount_unbound(conn, %ReviewState{files: [added, deleted]})
      render_click(view, "file.toggle_rendered", %{"file_name" => "a.md"})
      render_click(view, "file.toggle_rendered", %{"file_name" => "d.md"})

      assert has_element?(view, "#file-0 .md-preview .md-ins")
      assert has_element?(view, "#file-1 .md-preview .md-del")
    end

    test "files without a generated flag get no show-generated chip", %{conn: conn} do
      view = mount_unbound(conn, %ReviewState{files: [Map.delete(@plain_file, :is_generated)]})
      open_files_panel(view)
      assert has_element?(view, ".file-filter")
      refute has_element?(view, "[phx-click='filter.toggle_generated']")
    end
  end
end
