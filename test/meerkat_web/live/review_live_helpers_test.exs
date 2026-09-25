defmodule MeerkatWeb.ReviewLiveHelpersTest do
  # Pins the pure helpers of `MeerkatWeb.ReviewLive` through their
  # `*_for_test` seams (same pattern as cli.ex's decide_from_verdicts /
  # args_error shims). The handlers stay thin wiring; the branchy
  # logic — clamps, validators, filter composition, payload shapes —
  # is what these tests assert on. muex runs ExUnit only, so these
  # are the tests that kill mutants in the pure logic the Playwright
  # suite exercises only indirectly.
  use ExUnit.Case, async: true

  alias Meerkat.ReviewState
  alias MeerkatWeb.ReviewLive

  @rs %ReviewState{
    files: [
      %{file_name: "src/widget.rs", status: :modified, is_generated: false},
      %{file_name: "README.md", status: :modified, is_generated: false},
      %{file_name: "gen/locks.gen", status: :modified, is_generated: true},
      %{file_name: "vendor/dep.lock", status: :modified, is_generated: false}
    ],
    approved_file_names: MapSet.new(["README.md"]),
    hidden_extensions: MapSet.new(["lock"]),
    file_overrides: %{},
    show_generated: false
  }

  describe "parse_int (defensive client-payload parsing)" do
    test "integers pass through" do
      assert ReviewLive.parse_int_for_test(3) == {:ok, 3}
      assert ReviewLive.parse_int_for_test(0) == {:ok, 0}
      assert ReviewLive.parse_int_for_test(-2) == {:ok, -2}
    end

    test "well-formed strings parse" do
      assert ReviewLive.parse_int_for_test("3") == {:ok, 3}
      assert ReviewLive.parse_int_for_test("0") == {:ok, 0}
    end

    test "junk returns :error instead of raising" do
      assert ReviewLive.parse_int_for_test("abc") == :error
      assert ReviewLive.parse_int_for_test("3x") == :error
      assert ReviewLive.parse_int_for_test("") == :error
      assert ReviewLive.parse_int_for_test(nil) == :error
      assert ReviewLive.parse_int_for_test(%{}) == :error
      assert ReviewLive.parse_int_for_test(1.5) == :error
    end
  end

  describe "toolbar clamps and validators" do
    test "font size clamps into [9, 28]" do
      assert ReviewLive.clamp_font_size_for_test(13) == 13
      assert ReviewLive.clamp_font_size_for_test(1) == 9
      assert ReviewLive.clamp_font_size_for_test(-5) == 9
      assert ReviewLive.clamp_font_size_for_test(28) == 28
      assert ReviewLive.clamp_font_size_for_test(99) == 28
    end

    test "tab size allows only 2, 4, 8 — anything else falls back to 2" do
      assert ReviewLive.clamp_tab_size_for_test(2) == 2
      assert ReviewLive.clamp_tab_size_for_test(4) == 4
      assert ReviewLive.clamp_tab_size_for_test(8) == 8
      assert ReviewLive.clamp_tab_size_for_test(3) == 2
      assert ReviewLive.clamp_tab_size_for_test(16) == 2
    end

    test "settings.load validators keep defaults on junk" do
      defaults = %{diff_mode: "split", wrap_lines: true, font_size_px: 13, tab_size: 2}

      assert ReviewLive.valid_settings_for_test(%{}, defaults) == defaults

      assert ReviewLive.valid_settings_for_test(
               %{
                 "diff_mode" => "unified",
                 "wrap_lines" => false,
                 "font_size_px" => 20,
                 "tab_size" => 4
               },
               defaults
             ) == %{diff_mode: "unified", wrap_lines: false, font_size_px: 20, tab_size: 4}

      assert ReviewLive.valid_settings_for_test(
               %{
                 "diff_mode" => " sideways",
                 "wrap_lines" => "yes",
                 "font_size_px" => "big",
                 "tab_size" => 7
               },
               defaults
             ) == defaults
    end
  end

  describe "toolbar_title precedence: PR title > commit subject > head branch" do
    test "PR title wins when present" do
      assert ReviewLive.toolbar_title_for_test(%ReviewState{pr: %{title: "Fix the thing"}}) ==
               "Fix the thing"
    end

    test "commit-message subject is the first line, trimmed" do
      assert ReviewLive.toolbar_title_for_test(%ReviewState{
               commit_message: "  subject line\n\nbody"
             }) ==
               "subject line"
    end

    test "head branch name is the third fallback" do
      assert ReviewLive.toolbar_title_for_test(%ReviewState{head_branch: "fix-thing"}) ==
               "fix-thing"
    end

    test "empty everything renders as empty string" do
      assert ReviewLive.toolbar_title_for_test(%ReviewState{}) == ""
    end
  end

  describe "commit_msg_seed_code (suggestion-mode seed text)" do
    @msg "line one\nline two\nline three"

    test "slices the anchored line range out of the message" do
      assert ReviewLive.commit_msg_seed_code_for_test(@msg, %{start_line: 2, end_line: 3}) ==
               "line two\nline three"

      assert ReviewLive.commit_msg_seed_code_for_test(@msg, %{start_line: 1, end_line: 1}) ==
               "line one"
    end

    test "degenerate or out-of-range anchors yield empty seed" do
      assert ReviewLive.commit_msg_seed_code_for_test(@msg, %{start_line: 5, end_line: 9}) == ""
      assert ReviewLive.commit_msg_seed_code_for_test(@msg, %{start_line: 3, end_line: 1}) == ""
    end

    test "non-binary message or malformed anchor yields empty seed" do
      assert ReviewLive.commit_msg_seed_code_for_test(nil, %{start_line: 1, end_line: 1}) == ""
      assert ReviewLive.commit_msg_seed_code_for_test(@msg, %{start_line: 0, end_line: 1}) == ""
      assert ReviewLive.commit_msg_seed_code_for_test(@msg, :bogus) == ""
    end
  end

  describe "extract_snippet (inline suggestion seed)" do
    @snip_file %{
      file_name: "f.ex",
      old_content: "old a\nold b",
      new_content: "new a\nnew b\nnew c"
    }

    test "slices the new side by default and via \"new\"" do
      assert ReviewLive.extract_snippet_for_test(@snip_file, 2, 3, "new") == "new b\nnew c"
      assert ReviewLive.extract_snippet_for_test(@snip_file, 1, 1, :new) == "new a"
    end

    test "slices the old side" do
      assert ReviewLive.extract_snippet_for_test(@snip_file, 1, 2, "old") == "old a\nold b"
      assert ReviewLive.extract_snippet_for_test(@snip_file, 1, 2, :old) == "old a\nold b"
    end

    test "unknown side, missing content, or missing file yield empty" do
      assert ReviewLive.extract_snippet_for_test(@snip_file, 1, 1, "middle") == ""
      assert ReviewLive.extract_snippet_for_test(%{file_name: "f"}, 1, 1, "new") == ""
      assert ReviewLive.extract_snippet_for_test(nil, 1, 1, "new") == ""
    end
  end

  describe "draft keys" do
    test "global form has no anchor suffix" do
      assert ReviewLive.draft_key_for_test(:global, %{}, "r1", nil) == "meerkat:draft:r1:global"

      assert ReviewLive.draft_key_for_test(:global, %{}, nil, nil) ==
               "meerkat:draft:unbound:global"
    end

    test "file form scopes by file index" do
      assert ReviewLive.draft_key_for_test(:file, %{file_index: 2}, "r1", nil) ==
               "meerkat:draft:r1:file:2"
    end

    test "commit-msg form scopes by line range" do
      assert ReviewLive.draft_key_for_test(:commit_msg, %{start_line: 3, end_line: 5}, "r1", nil) ==
               "meerkat:draft:r1:commit_msg:3-5"
    end

    test "inline form scopes by index, side and range" do
      assert ReviewLive.draft_key_for_test(
               :inline,
               %{file_index: 1, start_line: 4, end_line: 6, side: "new"},
               "r1",
               nil
             ) == "meerkat:draft:r1:inline:1:new:4-6"
    end

    test "edit mode appends the comment id" do
      assert ReviewLive.draft_key_for_test(:file, %{file_index: 2}, "r1", "c9") ==
               "meerkat:draft:r1:file:2:edit:c9"

      # A nil edit id must NOT leave a dangling :edit: segment.
      refute ReviewLive.draft_key_for_test(:file, %{file_index: 2}, "r1", nil) =~ ":edit:"
    end
  end

  describe "visible_indices (filter composition)" do
    test "everything visible with no filters" do
      bare = %ReviewState{files: @rs.files, hidden_extensions: MapSet.new(), show_generated: true}
      assert ReviewLive.visible_indices_for_test(bare, "", nil) == MapSet.new([0, 1, 2, 3])
    end

    test "generated files hidden unless shown" do
      assert ReviewLive.visible_indices_for_test(@rs, "", nil) == MapSet.new([0, 1])

      shown = %ReviewState{@rs | show_generated: true}
      # The generated file appears; the .lock extension stays hidden.
      assert ReviewLive.visible_indices_for_test(shown, "", nil) == MapSet.new([0, 1, 2])
    end

    test "hidden extensions drop matching files" do
      shown = %ReviewState{@rs | show_generated: true}
      without_lock_file = %{shown | files: List.delete_at(@rs.files, 3)}

      assert ReviewLive.visible_indices_for_test(shown, "", nil) ==
               ReviewLive.visible_indices_for_test(without_lock_file, "", nil)
    end

    test "only_file_index hides every other file" do
      assert ReviewLive.visible_indices_for_test(@rs, "", 0) == MapSet.new([0])
    end

    test "substring filter matches on the base name, case-insensitive" do
      assert ReviewLive.visible_indices_for_test(@rs, "WIDGET", nil) == MapSet.new([0])
      assert ReviewLive.visible_indices_for_test(@rs, "read", nil) == MapSet.new([1])
      assert ReviewLive.visible_indices_for_test(@rs, "no-such-file", nil) == MapSet.new([])
    end

    test "per-file overrides win over every default filter" do
      shown_generated = put_in(@rs.file_overrides, %{"gen/locks.gen" => :show})

      assert ReviewLive.visible_indices_for_test(shown_generated, "", nil) ==
               MapSet.new([0, 1, 2])

      hidden_generated = put_in(@rs.file_overrides, %{"gen/locks.gen" => :hide})

      fully_shown = %ReviewState{@rs | show_generated: true}

      assert ReviewLive.visible_indices_for_test(hidden_generated, "", nil) ==
               MapSet.new([0, 1])

      assert ReviewLive.visible_indices_for_test(fully_shown, "", nil) !=
               ReviewLive.visible_indices_for_test(hidden_generated, "", nil)
    end

    test "a :show override still respects only_file_index and filter_input" do
      shown = put_in(@rs.file_overrides, %{"gen/locks.gen" => :show})
      assert ReviewLive.visible_indices_for_test(shown, "", 0) == MapSet.new([0])
      assert ReviewLive.visible_indices_for_test(shown, "widget", nil) == MapSet.new([0])
    end
  end

  describe "matched_file_names (bulk hide/show scope)" do
    test "empty input matches every file" do
      assert ReviewLive.matched_file_names_for_test(@rs, "") ==
               ["src/widget.rs", "README.md", "gen/locks.gen", "vendor/dep.lock"]
    end

    test "substring matches on base name" do
      assert ReviewLive.matched_file_names_for_test(@rs, "lock") ==
               ["gen/locks.gen", "vendor/dep.lock"]
    end
  end

  describe "filter_sidebar_entries" do
    test "empty input returns every file with its index" do
      assert ReviewLive.filter_sidebar_entries_for_test(@rs.files, "") ==
               Enum.with_index(@rs.files)
    end

    test "substring narrows on the base name, keeping original indices" do
      entries = ReviewLive.filter_sidebar_entries_for_test(@rs.files, "readme")
      assert entries == [{Enum.at(@rs.files, 1), 1}]
    end
  end

  describe "file_section_collapsed? (caret XOR semantics)" do
    test "approved files default to collapsed" do
      assert ReviewLive.file_section_collapsed_for_test(
               @rs,
               MapSet.new(),
               MapSet.new(),
               "README.md"
             )
    end

    test "unapproved files default to expanded" do
      refute ReviewLive.file_section_collapsed_for_test(
               @rs,
               MapSet.new(),
               MapSet.new(),
               "src/widget.rs"
             )
    end

    test "explicit toggles flip the default on either side" do
      expanded = MapSet.new(["README.md"])
      refute ReviewLive.file_section_collapsed_for_test(@rs, expanded, MapSet.new(), "README.md")

      collapsed = MapSet.new(["src/widget.rs"])

      assert ReviewLive.file_section_collapsed_for_test(
               @rs,
               MapSet.new(),
               collapsed,
               "src/widget.rs"
             )
    end
  end

  describe "find_comment (per-surface lookup)" do
    @comments %{
      comments: [%{id: "i1", body: "inline"}],
      file_comments: [%{id: "f1", body: "file"}],
      global_comments: [%{id: "g1", body: "global"}],
      commit_message_comments: [%{id: "c1", body: "commit msg"}]
    }

    test "looks up in the surface's own list" do
      assert ReviewLive.find_comment_for_test(@comments, "inline", "i1").body == "inline"
      assert ReviewLive.find_comment_for_test(@comments, "file", "f1").body == "file"
      assert ReviewLive.find_comment_for_test(@comments, "global", "g1").body == "global"

      assert ReviewLive.find_comment_for_test(@comments, "commit_msg", "c1").body ==
               "commit msg"
    end

    test "missing id or wrong surface yields nil" do
      assert ReviewLive.find_comment_for_test(@comments, "inline", "f1") == nil
      assert ReviewLive.find_comment_for_test(@comments, "global", "nope") == nil
    end
  end

  describe "github_payload (PENDING review shape)" do
    @pr_state %ReviewState{
      files: [%{file_name: "src/widget.rs"}, %{file_name: "lib/other.ex"}],
      pr: %{number: 7, title: "t", url: "u"},
      global_comments: [
        %{finding_type: :issue, body: "global note", learn_from_this: false, id: "g1"}
      ],
      comments: [
        %{
          id: "i1",
          file_index: 0,
          side: "new",
          start_line: 2,
          end_line: 2,
          finding_type: :suggestion,
          body: "swap it",
          learn_from_this: true
        },
        %{
          id: "i2",
          file_index: 1,
          side: "old",
          start_line: 3,
          end_line: 5,
          finding_type: "",
          body: "multi-line",
          learn_from_this: false
        }
      ]
    }

    test "event is PENDING with a body and per-line comments" do
      payload = ReviewLive.github_payload_for_test(@pr_state)
      assert payload.event == "PENDING"
      assert length(payload.comments) == 2
    end

    test "single-line inline comment uses line + side" do
      [first, _] = ReviewLive.github_payload_for_test(@pr_state).comments

      assert first == %{
               path: "src/widget.rs",
               line: 2,
               side: "RIGHT",
               body:
                 "**suggestion:** swap it\n\n_please learn from this: save a memory, update a skill, or " <>
                   "tighten the review-agent prompt so this class of issue is caught next time._"
             }
    end

    test "multi-line inline comment uses start_line + start_side" do
      [_, second] = ReviewLive.github_payload_for_test(@pr_state).comments
      assert second.start_line == 3
      assert second.line == 5
      assert second.start_side == "LEFT"
      assert second.side == "LEFT"
    end

    test "unknown file index degrades to an empty path" do
      state = %ReviewState{
        @pr_state
        | comments: [%{(@pr_state.comments |> hd()) | file_index: 9}]
      }

      [%{path: path} | _] = ReviewLive.github_payload_for_test(state).comments
      assert path == ""
    end
  end

  describe "stale_oid_check (pure clauses)" do
    @oid_file %{file_name: "f.ex", effective_oid: "abc123"}

    test "un-approving always proceeds" do
      assert ReviewLive.stale_oid_check_for_test("/repo", @file, false) == :ok
    end

    test "nil effective_oid (range/PR mode) skips the check" do
      assert ReviewLive.stale_oid_check_for_test(
               "/repo",
               %{file_name: "f", effective_oid: nil},
               true
             ) ==
               :ok
    end

    test "missing rendered file skips the check" do
      assert ReviewLive.stale_oid_check_for_test("/repo", nil, true) == :ok
    end

    test "deleted files have no staged blob to verify — pass through" do
      assert ReviewLive.stale_oid_check_for_test(
               "/repo",
               %{file_name: "f", status: :deleted},
               true
             ) ==
               :ok
    end

    test "empty effective_oid blocks the approve (staged lookup failed at mount)" do
      {:stale, msg} =
        ReviewLive.stale_oid_check_for_test(
          "/repo",
          %{file_name: "f.ex", effective_oid: ""},
          true
        )

      assert msg =~ "refresh the review"
    end
  end

  describe "finding atom whitelist" do
    test "known labels map to atoms, including legacy aliases" do
      assert ReviewLive.finding_atom_for_test("issue") == :issue
      assert ReviewLive.finding_atom_for_test("suggestion") == :suggestion
      assert ReviewLive.finding_atom_for_test("question") == :question
      assert ReviewLive.finding_atom_for_test("follow-up") == :follow_up
      assert ReviewLive.finding_atom_for_test("follow_up") == :follow_up
      assert ReviewLive.finding_atom_for_test("thought") == :follow_up
      assert ReviewLive.finding_atom_for_test("revert") == :revert
    end

    test "unknown labels raise instead of minting an atom" do
      assert_raise FunctionClauseError, fn -> ReviewLive.finding_atom_for_test("hax") end
    end
  end

  describe "surface_atom whitelist" do
    test "strings and matching atoms map to atoms; others raise" do
      assert ReviewLive.surface_atom_for_test("global") == :global
      assert ReviewLive.surface_atom_for_test("file") == :file
      assert ReviewLive.surface_atom_for_test("commit_msg") == :commit_msg
      assert ReviewLive.surface_atom_for_test("inline") == :inline
      assert ReviewLive.surface_atom_for_test(:inline) == :inline
      assert_raise FunctionClauseError, fn -> ReviewLive.surface_atom_for_test("nope") end
    end
  end

  describe "finding_label (badge text)" do
    test "follow-up renders under every historical spelling" do
      assert ReviewLive.finding_label_for_test(:follow_up) == "follow-up"
      assert ReviewLive.finding_label_for_test("follow_up") == "follow-up"
      assert ReviewLive.finding_label_for_test("thought") == "follow-up"
      assert ReviewLive.finding_label_for_test(:thought) == "follow-up"
    end

    test "other types render as their string form" do
      assert ReviewLive.finding_label_for_test(:issue) == "issue"
      assert ReviewLive.finding_label_for_test("suggestion") == "suggestion"
    end
  end

  describe "anchor_for / anchor_extras (per-surface anchors)" do
    @comment %{file_index: 1, start_line: 2, end_line: 3, side: "new"}

    test "file anchor keeps only the file index" do
      assert ReviewLive.anchor_for_test(:file, @comment) == %{file_index: 1}
      assert ReviewLive.anchor_extras_for_test(:file, @comment) == %{file_index: 1}
    end

    test "commit_msg anchor keeps the line range" do
      assert ReviewLive.anchor_for_test(:commit_msg, @comment) == %{start_line: 2, end_line: 3}

      assert ReviewLive.anchor_extras_for_test(:commit_msg, @comment) ==
               %{start_line: 2, end_line: 3}
    end

    test "inline anchor keeps everything" do
      assert ReviewLive.anchor_for_test(:inline, @comment) == @comment
      assert ReviewLive.anchor_extras_for_test(:inline, @comment) == @comment
    end

    test "global anchor is empty" do
      assert ReviewLive.anchor_for_test(:global, @comment) == %{}
      assert ReviewLive.anchor_extras_for_test(:global, @comment) == %{}
    end
  end

  describe "done_view / done_heading" do
    test "maps decisions to done views" do
      assert ReviewLive.done_view_for_test(nil) == nil
      assert ReviewLive.done_view_for_test({:approve, ""}) == :approve
      assert ReviewLive.done_view_for_test({:approve_with_feedback, "x"}) == :approve
      assert ReviewLive.done_view_for_test({:timeout, ""}) == :approve
      assert ReviewLive.done_view_for_test({:reject, "x"}) == :reject
      assert ReviewLive.done_view_for_test({:cancel, ""}) == :cancel
    end
  end

  describe "countdown_title" do
    test "names what happens when the review times out" do
      assert ReviewLive.countdown_title_for_test(:approve) =~ "auto-approved unread"
      assert ReviewLive.countdown_title_for_test(:wait) =~ "The review stays open after that."
    end
  end

  describe "page_title" do
    test "PR number or commit-review fallback" do
      assert ReviewLive.page_title_for_test(%ReviewState{pr: %{number: 7}}) == "meerkat — PR #7"
      assert ReviewLive.page_title_for_test(%ReviewState{}) == "meerkat commit review"
    end
  end

  describe "comments? / comment_count" do
    test "counts across all four surfaces" do
      state = %ReviewState{
        comments: [%{}, %{}],
        file_comments: [%{}],
        global_comments: [%{}, %{}, %{}],
        commit_message_comments: []
      }

      assert ReviewLive.comment_count_for_test(state) == 6
      assert ReviewLive.comments_for_test(state) == true
      assert ReviewLive.comments_for_test(%ReviewState{}) == false
    end
  end

  describe "effective_oid_for / markdown_file? / extension_of / file_path_dir" do
    @files [
      %{file_name: "src/a.ex", effective_oid: "oid1"},
      %{file_name: "README.md", effective_oid: "oid2"},
      %{file_name: "gen/x.lock", effective_oid: ""}
    ]

    test "effective_oid_for finds the file's oid" do
      state = %ReviewState{files: @files}
      assert ReviewLive.effective_oid_for_test(state, "README.md") == "oid2"
      assert ReviewLive.effective_oid_for_test(state, "missing") == nil
    end

    test "markdown_file? is extension-driven and never true for binaries" do
      assert ReviewLive.markdown_file_for_test(%{file_name: "README.md"}) == true
      assert ReviewLive.markdown_file_for_test(%{file_name: "notes.markdown"}) == true
      assert ReviewLive.markdown_file_for_test(%{file_name: "README.MD"}) == true
      assert ReviewLive.markdown_file_for_test(%{file_name: "src/a.ex"}) == false
      assert ReviewLive.markdown_file_for_test(%{file_name: "x.md", is_binary: true}) == false
    end

    test "extension_of strips the dot; extensionless files are empty" do
      assert ReviewLive.extension_of_for_test("src/a.ex") == "ex"
      assert ReviewLive.extension_of_for_test("README") == ""
    end

    test "file_path_dir keeps the directory prefix; root files have none" do
      assert ReviewLive.file_path_dir_for_test("src/a.ex") == "src/"
      assert ReviewLive.file_path_dir_for_test("README") == ""
    end
  end

  describe "gutter_label / status badge + label" do
    test "gutter label distinguishes single-line from range" do
      assert ReviewLive.gutter_label_for_test(%{start_line: 3, end_line: 3}) ==
               "Comment on commit message line 3"

      assert ReviewLive.gutter_label_for_test(%{start_line: 3, end_line: 5}) ==
               "Comment on commit message lines 3 through 5"
    end

    test "status badges and labels cover all four statuses" do
      assert ReviewLive.status_badge_for_test(:added) == "A"
      assert ReviewLive.status_badge_for_test(:modified) == "M"
      assert ReviewLive.status_badge_for_test(:deleted) == "D"
      assert ReviewLive.status_badge_for_test(:renamed) == "R"

      assert ReviewLive.status_label_for_test(:added) == "Added"
      assert ReviewLive.status_label_for_test(:modified) == "Modified"
      assert ReviewLive.status_label_for_test(:deleted) == "Deleted"
      assert ReviewLive.status_label_for_test(:renamed) == "Renamed"
    end
  end

  describe "comment grouping (per-file pre-grouping for render)" do
    @now "2026-01-01T00:00:00Z"

    test "inline comments group by file index and sort by line then time" do
      grouped =
        ReviewLive.group_inline_by_file_for_test([
          %{
            id: "b",
            file_index: 0,
            start_line: 5,
            created_at: @now,
            body: "b",
            finding_type: :issue
          },
          %{
            id: "a",
            file_index: 0,
            start_line: 2,
            created_at: @now,
            body: "a",
            finding_type: :issue
          },
          %{
            id: "c",
            file_index: 1,
            start_line: 1,
            created_at: @now,
            body: "c",
            finding_type: :issue
          }
        ])

      assert Map.keys(grouped) |> Enum.sort() == [0, 1]
      assert [%{id: "a"}, %{id: "b"}] = grouped[0]
      assert [%{id: "c"}] = grouped[1]
    end

    test "file comments group by file index with body_html attached" do
      grouped =
        ReviewLive.group_file_by_file_with_html_for_test([
          %{id: "f1", file_index: 2, body: "**bold**", finding_type: :issue}
        ])

      assert [%{id: "f1", body_html: html}] = grouped[2]
      assert html =~ "<strong>bold</strong>"
    end
  end

  # --- Second-pass kills (mutants the first batch didn't reach) ---

  describe "toolbar_title edge: empty PR title falls through to the next source" do
    test "empty PR title is not a title" do
      state = %ReviewState{pr: %{title: ""}, commit_message: "subject\n\nbody"}
      assert ReviewLive.toolbar_title_for_test(state) == "subject"
    end

    test "nil PR falls through to head branch" do
      assert ReviewLive.toolbar_title_for_test(%ReviewState{pr: nil, head_branch: "main"}) ==
               "main"
    end
  end

  describe "github_payload learn-from-this suffixes on folded sections" do
    @learn_state %ReviewState{
      files: [%{file_name: "a.ex"}],
      pr: %{number: 1},
      global_comments: [%{id: "g1", finding_type: :issue, body: "note", learn_from_this: true}],
      file_comments: [
        %{id: "f1", file_index: 0, finding_type: :issue, body: "file note", learn_from_this: true}
      ]
    }

    test "global section appends the learn suffix" do
      payload = ReviewLive.github_payload_for_test(@learn_state)
      assert payload.body =~ "note\n\n_please learn from this._"
    end

    test "file section carries the path header and the learn suffix" do
      payload = ReviewLive.github_payload_for_test(@learn_state)
      assert payload.body =~ "**a.ex**:\n\n**issue:** file note\n\n_please learn from this._"
    end
  end

  describe "missing_effective_oid?" do
    test "a real oid is not missing" do
      state = %ReviewState{files: [%{file_name: "a.ex", effective_oid: "abc"}]}
      refute ReviewLive.missing_effective_oid_for_test(state, "a.ex")
    end

    test "empty or missing oid is missing" do
      blank = %ReviewState{files: [%{file_name: "a.ex", effective_oid: ""}]}
      assert ReviewLive.missing_effective_oid_for_test(blank, "a.ex")

      absent = %ReviewState{files: [%{file_name: "other.ex", effective_oid: "abc"}]}
      assert ReviewLive.missing_effective_oid_for_test(absent, "a.ex")
    end
  end

  describe "github_payload non-learn comments stay bare" do
    test "no learn suffix without learn_from_this" do
      state = %ReviewState{
        files: [%{file_name: "a.ex"}],
        pr: %{number: 1},
        global_comments: [%{id: "g1", finding_type: :issue, body: "note", learn_from_this: false}],
        comments: [
          %{
            id: "i1",
            file_index: 0,
            side: "new",
            start_line: 1,
            end_line: 1,
            finding_type: :issue,
            body: "inline note",
            learn_from_this: false
          }
        ]
      }

      payload = ReviewLive.github_payload_for_test(state)
      refute payload.body =~ "learn from this"

      [%{body: inline_body}] = payload.comments
      refute inline_body =~ "learn from this"
    end
  end
end
