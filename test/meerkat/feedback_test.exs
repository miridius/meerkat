defmodule Meerkat.FeedbackTest do
  use ExUnit.Case, async: true

  alias Meerkat.{Comment, Feedback, ReviewState}

  defp state_with_global_comment do
    %ReviewState{
      global_comments: [
        %{
          id: Comment.new_id(),
          body: "needs work",
          finding_type: :issue,
          learn_from_this: false,
          created_at: Comment.now()
        }
      ]
    }
  end

  test "rejection framing leads with reviewer wants changes" do
    out = Feedback.format(state_with_global_comment(), "/tmp/repo", :rejection)
    assert out =~ "user reviewed your commit and wants changes before it lands"
    assert out =~ "needs work"
  end

  test "approval-with-feedback framing leads with reviewer approved but commented" do
    out = Feedback.format(state_with_global_comment(), "/tmp/repo", :approval_with_feedback)
    assert out =~ "user approved the commit but also left comments"
    assert out =~ "needs work"
  end

  test "approval-with-feedback with no comments returns empty" do
    assert Feedback.format(%ReviewState{}, "/tmp/repo", :approval_with_feedback) == ""
  end

  test "auto mode has no framing header" do
    out = Feedback.format(state_with_global_comment(), "/tmp/repo", :auto)
    refute out =~ "user reviewed your commit"
    refute out =~ "user approved the commit"
    assert out =~ "needs work"
  end

  describe "action_summary" do
    test "actionable-only — no action header (no question to disambiguate)" do
      # action_summary skips its render when there are no questions,
      # because the per-comment blocks below the framing are
      # self-explanatory. Adding a count line just to repeat them is
      # noise.
      state = %ReviewState{
        global_comments: [
          comment(body: "fix this", finding_type: :issue),
          comment(body: "consider this", finding_type: :suggestion)
        ]
      }

      out = Feedback.format(state, "/tmp/repo", :rejection)
      refute out =~ "ACTION:"
      assert out =~ "fix this"
      assert out =~ "consider this"
    end

    test "questions-only — answer directive, no code-change directive" do
      state = %ReviewState{
        global_comments: [comment(body: "why?", finding_type: :question)]
      }

      out = Feedback.format(state, "/tmp/repo", :rejection)
      assert out =~ "answer 1 question"
      refute out =~ "Address"
    end

    test "mixed — two-part action with both counts" do
      state = %ReviewState{
        global_comments: [
          comment(body: "fix", finding_type: :issue),
          comment(body: "why?", finding_type: :question)
        ]
      }

      out = Feedback.format(state, "/tmp/repo", :rejection)
      assert out =~ "Answer 1 question"
      assert out =~ "Address 1 feedback comment"
    end

    test "pluralisation: 1 question vs N questions" do
      one = %ReviewState{
        global_comments: [comment(body: "q1", finding_type: :question)]
      }

      many = %ReviewState{
        global_comments: [
          comment(body: "q1", finding_type: :question),
          comment(body: "q2", finding_type: :question)
        ]
      }

      assert Feedback.format(one, "/tmp/repo", :rejection) =~ "answer 1 question "
      assert Feedback.format(many, "/tmp/repo", :rejection) =~ "answer 2 questions"
    end
  end

  describe "has_questions?" do
    test "true when any comment is :question" do
      state = %ReviewState{
        global_comments: [comment(body: "why?", finding_type: :question)]
      }

      assert Feedback.has_questions?(state)
    end

    test "false when no comment is :question" do
      state = %ReviewState{
        global_comments: [comment(body: "fix", finding_type: :issue)]
      }

      refute Feedback.has_questions?(state)
    end

    test "false on empty state" do
      refute Feedback.has_questions?(%ReviewState{})
    end
  end

  describe "question_directive" do
    test "fires when any comment is :question — includes the JSON schema" do
      state = %ReviewState{
        global_comments: [comment(body: "why?", finding_type: :question)]
      }

      out = Feedback.format(state, "/tmp/repo", :rejection)
      assert out =~ "question"
      assert out =~ "pending-answers.json"
      assert out =~ ~s("version": 1)
      assert out =~ "answers"
    end

    test "does NOT fire when no question is present" do
      out = Feedback.format(state_with_global_comment(), "/tmp/repo", :rejection)
      refute out =~ "pending-answers.json"
    end

    test "renders <gitdir> placeholder when repo_path is nil" do
      state = %ReviewState{
        global_comments: [comment(body: "why?", finding_type: :question)]
      }

      out = Feedback.format(state, nil, :rejection)
      assert out =~ "<gitdir>/meerkat-precommit/pending-answers.json"
    end
  end

  describe "section renderers (via format/3)" do
    test "inline comment on the OLD side renders with `-` quote prefix tag" do
      state = %ReviewState{
        comments: [
          inline_comment(
            file_index: 0,
            start_line: 1,
            end_line: 1,
            side: :old,
            body: "this was here"
          )
        ],
        files: [%{file_name: "x.rs", old_content: "a\nb\nc", new_content: "A\nb\nc"}]
      }

      out = Feedback.format(state, "/tmp/repo", :rejection)
      assert out =~ "(old)"
      assert out =~ "this was here"
    end

    test "commit_message_comments surface renders with the commit-msg line tag" do
      state = %ReviewState{
        commit_message: "subject\n\nbody",
        commit_message_comments: [
          %{
            id: Comment.new_id(),
            start_line: 1,
            end_line: 1,
            body: "rewrite subject",
            finding_type: :suggestion,
            learn_from_this: false,
            created_at: Comment.now()
          }
        ]
      }

      out = Feedback.format(state, "/tmp/repo", :rejection)
      assert out =~ "Commit message comments"
      assert out =~ "commit-message:1"
      assert out =~ "rewrite subject"
    end

    test "inline comment carries file-index + line-range tag" do
      state = %ReviewState{
        comments: [
          inline_comment(file_index: 3, start_line: 10, end_line: 12, body: "tighten")
        ],
        files: [%{}, %{}, %{}, %{file_name: "src/x.rs", new_content: "a\nb\nc\nd\ne\nf"}]
      }

      out = Feedback.format(state, "/tmp/repo", :rejection)
      assert out =~ "src/x.rs:10-12"
      assert out =~ "(new)"
      assert out =~ "tighten"
    end

    test "revert with empty body renders the synthesised `restore from HEAD` label" do
      # Empty-body revert renders subject-less because the comment's
      # anchor above already names the line range. HEAD is staged-
      # mode-precise (the only mode meerkat ships in practice) —
      # avoids the agent reading "revert" as "undo my latest
      # in-session edit" or "go back to some PR-ago state".
      state = %ReviewState{
        global_comments: [comment(body: "", finding_type: :revert)]
      }

      out = Feedback.format(state, "/tmp/repo", :rejection)
      assert out =~ "restore from HEAD"
    end

    test "learn_from_this prints the please-learn-from-this directive" do
      state = %ReviewState{
        global_comments: [comment(body: "fix", finding_type: :issue, learn_from_this: true)]
      }

      out = Feedback.format(state, "/tmp/repo", :rejection)
      assert out =~ "please-learn-from-this:"
      assert out =~ "internalising"
    end
  end

  defp comment(overrides) do
    Enum.into(overrides, %{
      id: Comment.new_id(),
      body: "x",
      finding_type: :issue,
      learn_from_this: false,
      created_at: Comment.now()
    })
  end

  defp inline_comment(overrides) do
    Enum.into(overrides, %{
      id: Comment.new_id(),
      file_index: 0,
      start_line: 1,
      end_line: 1,
      side: :new,
      body: "x",
      finding_type: :issue,
      learn_from_this: false,
      created_at: Comment.now()
    })
  end
end
