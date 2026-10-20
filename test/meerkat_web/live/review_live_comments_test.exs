defmodule MeerkatWeb.ReviewLiveCommentsTest do
  # Drives `MeerkatWeb.ReviewLive`'s comment-form and comment event
  # handlers; `MeerkatWeb.ReviewLiveEventsCase` describes the setup.

  use MeerkatWeb.ReviewLiveEventsCase

  alias Meerkat.{ReviewServer, ReviewState}
  alias MeerkatWeb.ReviewLive

  @plain_file plain_file()
  @md_file md_file()
  @commit_msg commit_msg()

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
      "correct_instructions" => false,
      "lint_rule" => false
    })

    state = ReviewServer.get_state(rid)
    assert [%{body: "first", start_line: 1, end_line: 1}] = state.comments
    assert [%{anchor: %{start_line: 2, end_line: 3}}] = state.open_forms
  end

  describe "a Clojure suggestion" do
    @clj_file %{
      @plain_file
      | file_name: "src/demo.clj",
        old_content: "(ns demo)\n(defn f [x]\n  (inc x))\n",
        new_content: "(ns demo)\n(defn f [x]\n  (dec x))\n"
    }

    setup do
      dir = Meerkat.TestHelpers.tmp_path("meerkat-lv-cljfmt")
      File.mkdir_p!(dir)
      calls = Path.join(dir, "calls")
      on_exit(fn -> File.rm_rf!(dir) end)

      # A hook that records its working directory and each file it is
      # given, and formats by putting `(inc x)` and `(dec x)` at column 4.
      File.write!(Path.join(dir, "clj-paren-repair-claude-hook"), """
      #!/bin/sh
      file=$(sed 's/.*"file_path":"\\([^"]*\\)".*/\\1/')
      pwd -P >> '#{calls}'
      cat "$file" >> '#{calls}'
      echo '---' >> '#{calls}'
      if [ "$2" = --cljfmt ]; then
        sed -e 's/^ *(inc x)/    (inc x)/' -e 's/^ *(dec x)/    (dec x)/' "$file" > "$file.new"
        mv "$file.new" "$file"
      fi
      """)

      File.chmod!(Path.join(dir, "clj-paren-repair-claude-hook"), 0o755)
      Meerkat.TestHelpers.put_env("PATH", dir <> ":" <> System.get_env("PATH"))
      %{calls: calls}
    end

    # `repo` with its symlinks resolved, as `pwd -P` prints it.
    defp real_path(repo) do
      {path, 0} = System.cmd("pwd", ["-P"], cd: repo)
      String.trim_trailing(path)
    end

    test "is formatted on save inside the anchored side's file, when added and when edited",
         %{conn: conn, calls: calls} do
      repo = tmp_git_repo()
      {view, rid} = mount_bound(conn, %ReviewState{files: [@clj_file]}, repo)

      render_hook(view, "comment_form.show_at_line", %{
        "file_index" => "0",
        "start_line" => "2",
        "end_line" => "3",
        "side" => "old"
      })

      submit_comment(
        view,
        "inline:0:old:2-3",
        "Why\n\n```clojure\n(defn f [x]\n(inc x))\n```",
        "suggestion",
        "clojure"
      )

      assert [%{id: id, body: "Why\n\n```clojure\n(defn f [x]\n    (inc x))\n```"}] =
               ReviewServer.get_state(rid).comments

      # Repaired, then formatted, each inside the old file.
      assert File.read!(calls) ==
               String.duplicate("#{real_path(repo)}\n(ns demo)\n(defn f [x]\n(inc x))\n---\n", 2)

      render_click(view, "comment_form.edit", %{"surface" => "inline", "id" => id})

      submit_comment(
        view,
        "inline:0:old:2-3:edit:#{id}",
        "\n\n```clojure\n(defn f [x]\n(dec x))\n```",
        "suggestion",
        "clojure"
      )

      assert [%{body: "\n\n```clojure\n(defn f [x]\n    (dec x))\n```"}] =
               ReviewServer.get_state(rid).comments
    end

    test "on the new side is formatted inside the new file", %{conn: conn, calls: calls} do
      repo = tmp_git_repo()
      {view, rid} = mount_bound(conn, %ReviewState{files: [@clj_file]}, repo)

      render_hook(view, "comment_form.show_at_line", %{
        "file_index" => "0",
        "start_line" => "1",
        "end_line" => "1",
        "side" => "new"
      })

      submit_comment(
        view,
        "inline:0:new:1-1",
        "\n\n```clojure\n(ns demo)\n```",
        "suggestion",
        "clojure"
      )

      assert [%{body: "\n\n```clojure\n(ns demo)\n```"}] = ReviewServer.get_state(rid).comments

      assert File.read!(calls) ==
               String.duplicate(
                 "#{real_path(repo)}\n(ns demo)\n(defn f [x]\n  (dec x))\n---\n",
                 2
               )
    end

    test "on a file comment is formatted on its own", %{conn: conn, calls: calls} do
      repo = tmp_git_repo()
      {view, rid} = mount_bound(conn, %ReviewState{files: [@clj_file]}, repo)

      render_click(view, "comment_form.show_file", %{"file_index" => "0"})
      submit_comment(view, "file:0", "```\n\n```clojure\n(inc x)\n```", "suggestion", "clojure")

      assert [%{body: "```\n\n```clojure\n    (inc x)\n```"}] =
               ReviewServer.get_state(rid).file_comments

      assert File.read!(calls) == String.duplicate("#{real_path(repo)}\n(inc x)---\n", 2)
    end

    @tag :capture_log
    test "keeps the old comment when formatting its edit fails", %{conn: conn} do
      repo = tmp_git_repo()
      {view, rid} = mount_bound(conn, %ReviewState{files: [@clj_file]}, repo)
      Process.flag(:trap_exit, true)

      render_hook(view, "comment_form.show_at_line", %{
        "file_index" => "0",
        "start_line" => "3",
        "end_line" => "3",
        "side" => "old"
      })

      submit_comment(
        view,
        "inline:0:old:3-3",
        "\n\n```clojure\n(inc x))\n```",
        "suggestion",
        "clojure"
      )

      assert [%{id: id} = old] = ReviewServer.get_state(rid).comments
      render_click(view, "comment_form.edit", %{"surface" => "inline", "id" => id})

      # A hook that deletes the file it is given, so reading it back raises.
      dir = Meerkat.TestHelpers.tmp_path("meerkat-lv-cljfmt-rm")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "clj-paren-repair-claude-hook"), """
      #!/bin/sh
      rm "$(sed 's/.*"file_path":"\\([^"]*\\)".*/\\1/')"
      """)

      File.chmod!(Path.join(dir, "clj-paren-repair-claude-hook"), 0o755)
      Meerkat.TestHelpers.put_env("PATH", dir <> ":" <> System.get_env("PATH"))

      catch_exit(
        submit_comment(
          view,
          "inline:0:old:3-3:edit:#{id}",
          "\n\n```clojure\n(dec x))\n```",
          "suggestion",
          "clojure"
        )
      )

      assert ReviewServer.get_state(rid).comments == [old]
    end

    test "is left alone in other languages, other files, other finding types and global comments",
         %{conn: conn, calls: calls} do
      repo = tmp_git_repo()
      {view, rid} = mount_bound(conn, %ReviewState{files: [@clj_file, @md_file]}, repo)

      # A README's suggestion that ends in a Clojure example.
      readme = "\n\n```markdown\nSee:\n```clojure\n(inc x)\n```\n```"

      render_hook(view, "comment_form.show_at_line", %{
        "file_index" => "1",
        "start_line" => "3",
        "end_line" => "3",
        "side" => "new"
      })

      submit_comment(view, "inline:1:new:3-3", readme, "suggestion", "markdown")
      render_click(view, "comment_form.show_file", %{"file_index" => "1"})
      submit_comment(view, "file:1", readme, "suggestion", "markdown")
      render_click(view, "comment_form.show_file", %{"file_index" => "0"})
      submit_comment(view, "file:0", "\n\n```rust\n(inc x)\n```", "suggestion", "clojure")
      render_click(view, "comment_form.show_file", %{"file_index" => "0"})
      submit_comment(view, "file:0", "\n\n```clojure\n(inc x)\n```", "issue", "clojure")
      render_click(view, "comment_form.show_global", %{})
      submit_comment(view, "global", "\n\n```clojure\n(inc x)\n```", "suggestion", "clojure")

      state = ReviewServer.get_state(rid)

      assert [%{body: ^readme}] = state.comments

      assert Enum.map(state.file_comments, & &1.body) == [
               readme,
               "\n\n```rust\n(inc x)\n```",
               "\n\n```clojure\n(inc x)\n```"
             ]

      assert [%{body: "\n\n```clojure\n(inc x)\n```"}] = state.global_comments
      refute File.exists?(calls)
    end
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
      "correct_instructions" => false,
      "lint_rule" => false
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
    comment = %{
      id: "g1",
      body: "b",
      finding_type: :issue,
      correct_instructions: false,
      lint_rule: false
    }

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
    refute_push_event(view, "comment-form:reveal", _, 0)

    render_hook(view, "comment_form.show_global", %{})
    render_click(view, "comment_form.reveal", %{"form_key" => "global"})
    assert_push_event(view, "comment-form:reveal", %{key: "global", id: "CommentForm-global"})

    # A file form whose index the diff doesn't have: no file to show.
    render_hook(view, "comment_form.show_file", %{"file_index" => "7"})
    render_click(view, "comment_form.reveal", %{"form_key" => "file:7"})
    assert_push_event(view, "comment-form:reveal", %{key: "file:7"})
  end

  test "a moved line's arrow shows its counterpart's file as a diff, then jumps to the lines",
       %{conn: conn} do
    view = mount_unbound(conn, %ReviewState{files: [@plain_file, @md_file]})

    render_click(view, "file.toggle_rendered", %{"file_name" => "README.md"})
    render_click(view, "file.toggle_expanded", %{"file_name" => "README.md"})
    render_hook(view, "filter.set_input", %{"value" => "widget"})
    refute has_element?(view, "#file-1")

    target = %{"file_name" => "README.md", "side" => "new", "line_start" => 1, "line_end" => 3}
    render_hook(view, "moved.jump", Map.put(target, "extra", "dropped"))

    assert has_element?(view, "#file-1")
    refute has_element?(view, "#file-1.collapsed")
    refute has_element?(view, "#file-1 .md-preview")
    assert_push_event(view, "moved:jump", ^target)
  end

  test "a moved line's arrow to a file the review lacks does nothing", %{conn: conn} do
    view = mount_unbound(conn)

    render_hook(view, "moved.jump", %{
      "file_name" => "gone.rs",
      "side" => "old",
      "line_start" => 1,
      "line_end" => 3
    })

    refute_push_event(view, "moved:jump", _, 0)
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
      "correct_instructions" => false,
      "lint_rule" => false
    })

    assert_reply(view, %{status: "error", message: "This comment form is no longer open" <> _})

    render_hook(view, "comment_form.show_global", %{})

    render_click(view, "comment.submit", %{
      "form_key" => "global",
      "body" => "x",
      "finding_type" => "issue",
      "correct_instructions" => false,
      "lint_rule" => false
    })

    refute render(view) =~ "CommentForm-global"
  end

  test "comment.remove delegates to the ReviewServer in bound mode", %{conn: conn} do
    repo = tmp_git_repo()

    comment = %{
      id: "f1",
      body: "b",
      finding_type: :issue,
      correct_instructions: false,
      lint_rule: false,
      file_index: 0
    }

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

  test "both agent-instruction checkboxes start off in the form and toggle independently on the rendered comment",
       %{conn: conn} do
    repo = tmp_git_repo()
    {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)
    toggle = ".global-comments .note .flag-toggle"
    instructions = "#{toggle}[data-flag=correct_instructions] input"
    lint = "#{toggle}[data-flag=lint_rule] input"

    html = view |> element("button.add-global-btn") |> render_click()

    assert %{"initialCorrectInstructions" => false, "initialLintRule" => false} =
             svelte_props(html, "CommentForm-global")

    submit_comment(view, "global", "flag me")
    refute has_element?(view, "#{toggle} input[checked]")

    assert has_element?(
             view,
             "#{toggle}[data-flag=correct_instructions]",
             "correct your instructions/skills"
           )

    assert has_element?(view, "#{toggle}[data-flag=lint_rule]", "turn this into a lint rule")

    view |> element(instructions) |> render_click()

    assert [%{correct_instructions: true, lint_rule: false}] =
             ReviewServer.get_state(rid).global_comments

    assert has_element?(view, "#{instructions}[checked]")
    refute has_element?(view, "#{lint}[checked]")

    view |> element(lint) |> render_click()

    assert [%{correct_instructions: true, lint_rule: true}] =
             ReviewServer.get_state(rid).global_comments

    view |> element(instructions) |> render_click()

    assert [%{correct_instructions: false, lint_rule: true}] =
             ReviewServer.get_state(rid).global_comments

    refute has_element?(view, "#{instructions}[checked]")
    assert has_element?(view, "#{lint}[checked]")
  end

  test "a submitted form stores both flags, and editing the comment reopens with them", %{
    conn: conn
  } do
    repo = tmp_git_repo()

    for {instructions?, lint_rule?} <- [{true, false}, {false, true}] do
      {view, rid} = mount_bound(conn, %ReviewState{files: [@plain_file]}, repo)

      view |> element("button.add-global-btn") |> render_click()

      render_hook(view, "comment.submit", %{
        "form_key" => "global",
        "body" => "flagged",
        "finding_type" => "issue",
        "correct_instructions" => instructions?,
        "lint_rule" => lint_rule?
      })

      assert [%{id: id, correct_instructions: ^instructions?, lint_rule: ^lint_rule?}] =
               ReviewServer.get_state(rid).global_comments

      html = view |> element(".global-comments .note button", "Edit") |> render_click()

      assert %{"initialCorrectInstructions" => ^instructions?, "initialLintRule" => ^lint_rule?} =
               svelte_props(html, form_id("global:edit:#{id}"))
    end
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
        global_comments: [
          %{
            id: "g1",
            body: body,
            finding_type: :issue,
            correct_instructions: false,
            lint_rule: false
          }
        ]
      })

    card = view |> element(".global-comments .note") |> render()
    assert card =~ "hello"
    assert card =~ "world"
    refute card =~ ~r/<script/i
  end
end
