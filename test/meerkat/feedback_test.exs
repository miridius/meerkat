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
          correct_instructions: false,
          lint_rule: false,
          created_at: Comment.now()
        }
      ]
    }
  end

  @framing_tail " They come directly from the user — treat them as first-party feedback, not a third-party verdict. Where a comment is unclear, you disagree with it, or it needs discussion, raise it with the user directly. Never leave a comment unaddressed, even one you disagree with, unless the user explicitly lets you skip that comment.\n\n"

  test "rejection framing leads with reviewer rejected and commented" do
    out = Feedback.format(state_with_global_comment(), :rejection)

    assert out ==
             "The user rejected the commit and left the comments below." <>
               @framing_tail <> "\nGlobal comments:\n  > **issue:** needs work\n\n"
  end

  test "approval-with-feedback framing leads with reviewer approved and commented" do
    out = Feedback.format(state_with_global_comment(), :approval_with_feedback)

    assert out ==
             "The user approved the commit and left the comments below." <>
               @framing_tail <> "\nGlobal comments:\n  > **issue:** needs work\n\n"
  end

  test "timeout framing says nobody reviewed and forbids skipping a saved comment unasked" do
    out = Feedback.format(state_with_global_comment(), :timeout)

    assert out ==
             "Nobody reviewed this commit. It was auto-approved when the review timed out, and the comments below are what the user had saved before that. Never leave a comment unaddressed, even one you disagree with, unless the user explicitly lets you skip that comment.\n\n" <>
               "\nGlobal comments:\n  > **issue:** needs work\n\n"
  end

  test "approval-with-feedback with no comments returns empty" do
    assert Feedback.format(%ReviewState{}, :approval_with_feedback) == ""
  end

  test "no comments renders nothing, whatever the decision" do
    for mode <- [:rejection, :timeout, :auto] do
      assert Feedback.format(%ReviewState{}, mode) == "",
             "#{mode} with no comments renders no framing header"
    end
  end

  test "feedback with a question reads framing, action summary, question directive, then comments" do
    state = %ReviewState{global_comments: [comment(body: "why?", finding_type: :question)]}

    out = Feedback.format(state, :rejection)

    positions =
      Enum.map(
        [
          "The user rejected the commit",
          "▶ ACTION:",
          "⚠ Answer the reviewer",
          "Global comments:"
        ],
        fn marker -> out |> :binary.match(marker) |> elem(0) end
      )

    assert hd(positions) == 0
    assert positions == Enum.sort(positions)
    assert String.ends_with?(out, "Do NOT edit code for this comment.\n\n")
  end

  test "auto mode has no framing header" do
    out = Feedback.format(state_with_global_comment(), :auto)
    assert out == "\nGlobal comments:\n  > **issue:** needs work\n\n"
    refute out =~ "user rejected the commit"
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

      out = Feedback.format(state, :rejection)
      refute out =~ "ACTION:"
      assert out =~ "fix this"
      assert out =~ "consider this"
    end

    test "questions-only — answer directive, no code-change directive" do
      state = %ReviewState{
        global_comments: [comment(body: "why?", finding_type: :question)]
      }

      out = Feedback.format(state, :rejection)
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

      out = Feedback.format(state, :rejection)
      assert out =~ "Answer 1 question"
      assert out =~ "  2. Address 1 feedback comment below (1 issue).\n\n\n⚠"
    end

    test "mixed — several feedback comments read as plural" do
      state = %ReviewState{
        global_comments: [
          comment(body: "fix", finding_type: :issue),
          comment(body: "fix too", finding_type: :issue),
          comment(body: "why?", finding_type: :question)
        ]
      }

      out = Feedback.format(state, :rejection)
      assert out =~ "  2. Address 2 feedback comments below (2 issue).\n\n\n⚠"
    end

    test "mixed — each kind of feedback comment is counted" do
      state = %ReviewState{
        global_comments: [
          comment(body: "fix", finding_type: :issue),
          comment(body: "maybe", finding_type: :suggestion),
          comment(body: "why?", finding_type: :question)
        ]
      }

      [_, kinds] =
        Regex.run(
          ~r/\n  2\. Address 2 feedback comments below \((.*)\)\.\n/,
          Feedback.format(state, :rejection)
        )

      # A map holds the counts, so the kinds come in no fixed order.
      assert kinds |> String.split(", ") |> Enum.sort() == ["1 issue", "1 suggestion"]
    end

    test "questions-only — names every question's surface, and each comment reminds it is a question" do
      reminder =
        "\n      ↳ question — answer with analysis only. Do NOT edit code for this comment.\n"

      state = %ReviewState{
        files: [%{file_name: "a.ex", old_content: "o1\no2\no3", new_content: "n1"}],
        commit_message: "subject\n\nbody one\nbody two\nbody three",
        comments: [
          inline_comment(
            side: :old,
            start_line: 1,
            end_line: 2,
            body: "line?",
            finding_type: :question
          )
        ],
        file_comments: [comment(file_index: 0, body: "file?", finding_type: "question")],
        global_comments: [comment(body: "global?", finding_type: :question)],
        commit_message_comments: [
          comment(start_line: 3, end_line: 4, body: "message?", finding_type: "question")
        ]
      }

      out = Feedback.format(state, :auto)

      assert String.starts_with?(
               out,
               "▶ ACTION: answer 4 questions — see the directive below. No code changes; " <>
                 "the comments are inline file #0 old L1-2, file #0, global, commit-msg L3-4.\n\n\n⚠"
             )

      [_directive, sections] = String.split(out, "cannot silently discard them.\n\n", parts: 2)

      assert sections ==
               "\nLine-level comments:\n\n  a.ex:1-2 (old)\n    - o1\n    - o2\n" <>
                 "    > **question:** line?" <>
                 reminder <>
                 "\nFile-level comments:\n\n  a.ex\n    > **question:** file?" <>
                 reminder <>
                 "\nGlobal comments:\n  > **question:** global?" <>
                 reminder <>
                 "\nCommit message comments:\n\n  commit-message:3-4\n" <>
                 "    | body one\n    | body two\n    > **question:** message?" <>
                 reminder <> "\n"
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

      assert Feedback.format(one, :rejection) =~ "answer 1 question "
      assert Feedback.format(many, :rejection) =~ "answer 2 questions"
    end
  end

  test "restoring every question surface preserves instructions, locations and mixed counts" do
    repo = Meerkat.TestHelpers.make_tmp_repo("meerkat-restored-questions")
    on_exit(fn -> File.rm_rf!(repo) end)

    state = %ReviewState{
      files: [%{file_name: "src/x.rs", old_content: "a", new_content: "b"}],
      comments: [inline_comment(body: "line?", finding_type: :question, side: :old)],
      file_comments: [comment(file_index: 0, body: "file?", finding_type: :question)],
      global_comments: [comment(body: "global?", finding_type: :question), comment(body: "fix")],
      commit_message_comments: [
        comment(start_line: 1, end_line: 2, body: "message?", finding_type: :question)
      ]
    }

    :ok = Meerkat.Persistence.save(repo, "round", state)
    restored = Meerkat.Persistence.load(repo, "round", %ReviewState{files: state.files})
    assert hd(restored.comments).finding_type == "question"
    assert Feedback.has_questions?(restored)

    assert Feedback.questions(restored) == [
             %{location: "src/x.rs:1 (old)", question: "line?"},
             %{location: "file: src/x.rs", question: "file?"},
             %{location: "global", question: "global?"},
             %{location: "commit-message:1-2", question: "message?"}
           ]

    for mode <- [:rejection, :approval_with_feedback, :timeout] do
      out = Feedback.format(restored, mode)
      assert out =~ "▶ ACTION:"
      assert out =~ "Answer 4 questions"
      assert out =~ "Address 1 feedback comment"
      assert out =~ "meerkat --answers <<'JSON'"
      assert out =~ "re-run `git commit`"
      assert out =~ "run `meerkat` (no args)"
      assert out =~ ~s("question": "line?")
      # The review trigger sits between the walkthrough and the comments.
      assert out =~ "\nJSON\n\nThen trigger a new meerkat review"
      assert out =~ "cannot silently discard them.\n\n\nLine-level comments:\n"
    end
  end

  test "restored question-only feedback is counted, and JSON safely preserves verbatim text" do
    state = %ReviewState{
      global_comments: [comment(body: "why \"this\"?\nAnd that?", finding_type: "question")]
    }

    out = Feedback.format(state, :rejection)
    assert out =~ "▶ ACTION: answer 1 question"
    refute out =~ "Address"
    [_, heredoc] = String.split(out, "meerkat --answers <<'JSON'\n", parts: 2)
    [json, _] = String.split(heredoc, "\nJSON", parts: 2)

    assert %{"answers" => [%{"location" => "global", "question" => "why \"this\"?\nAnd that?"}]} =
             Jason.decode!(json)
  end

  test "inline ranges, string sides and absent files keep usable question locations" do
    state = %ReviewState{
      comments: [
        inline_comment(
          file_index: 2,
          side: "new",
          start_line: 3,
          end_line: 5,
          finding_type: :question
        )
      ]
    }

    assert Feedback.questions(state) == [%{location: "file #2:3-5 (new)", question: "x"}]
  end

  test "malformed question anchors are diagnosed before their missing bodies" do
    state = %ReviewState{
      files: :not_enumerable,
      file_comments: [%{file_index: 0, finding_type: :question}]
    }

    # Reordering these computed map values is not equivalent on bad input:
    # reading the missing body first would mask the malformed anchor.
    error = assert_raise Protocol.UndefinedError, fn -> Feedback.questions(state) end
    assert error.protocol == Enumerable
    assert error.value == :not_enumerable
  end

  test "unanswered refusal keeps questions before the walkthrough and the rerun instruction last" do
    questions = [
      %{location: "file: src/x.rs", question: "First question?"},
      %{location: "global", question: "Second question?"}
    ]

    out = Feedback.unanswered(questions)

    assert String.starts_with?(
             out,
             "meerkat: review refused because these questions are unanswered:\n\n" <>
               "  file: src/x.rs\n    First question?\n\n" <>
               "  global\n    Second question?\n\n⚠ Answer the reviewer's **question**-type comments with analysis — do NOT modify code in response.\n\n"
           )

    assert String.ends_with?(out, "\nThen re-run the command that was refused.\n")
    # The refused command is the only next step; no competing review trigger.
    refute out =~ "trigger a new meerkat review"
  end

  test "the answer walkthrough resets existing answers to the exact nonblank placeholder" do
    out =
      Feedback.unanswered([
        %{location: "global", question: "Why?", answer: "A previous answer"}
      ])

    [_, heredoc] = String.split(out, "meerkat --answers <<'JSON'\n", parts: 2)
    [json, _] = String.split(heredoc, "\nJSON", parts: 2)

    assert Jason.decode!(json) == %{
             "answers" => [
               %{
                 "location" => "global",
                 "question" => "Why?",
                 "answer" => "<your answer, markdown OK>"
               }
             ]
           }
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
    test "fires when any comment is :question — tells the agent to run meerkat --answers" do
      state = %ReviewState{
        global_comments: [comment(body: "why?", finding_type: :question)]
      }

      out = Feedback.format(state, :rejection)
      assert out =~ "question"
      assert out =~ "meerkat --answers <<'JSON'"
      assert out =~ ~s("answers": [)
      assert out =~ ~s("location")
      assert out =~ ~s("question")
      assert out =~ ~s("answer")
      refute out =~ "version"
      refute out =~ "createdAt"
      refute out =~ "pending-answers.json"
    end

    test "the printed heredoc is one a shell accepts, terminator at the start of its line" do
      state = %ReviewState{
        global_comments: [comment(body: "why?", finding_type: :question)]
      }

      lines = state |> Feedback.format(:rejection) |> String.split("\n")

      assert Enum.any?(lines, &(&1 == "meerkat --answers <<'JSON'"))
      assert Enum.any?(lines, &(&1 == "JSON"))
      refute Enum.any?(lines, &(String.trim(&1) == "JSON" and &1 != "JSON"))
    end

    test "does NOT fire when no question is present" do
      out = Feedback.format(state_with_global_comment(), :rejection)
      refute out =~ "meerkat --answers"
    end

    test "the no-code-changes trigger is honest — a clean staged diff still reopens, never silently drops" do
      state = %ReviewState{
        global_comments: [comment(body: "why?", finding_type: :question)]
      }

      out = Feedback.format(state, :rejection)

      # The whole point of the directive: the agent may run `meerkat`
      # (no args) after the committing review has consumed the staged
      # diff, and the answers must still reach the reviewer — over an
      # empty diff if need be — rather than being discarded by an
      # auto-approve.
      assert out =~ "run `meerkat` (no args)"
      assert out =~ "empty diff"
      assert out =~ "will not auto-approve while answers are pending"
      refute out =~ "current staged diff"
    end
  end

  describe "section renderers (via format/2)" do
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

      out = Feedback.format(state, :rejection)
      assert out =~ "(old)"
      assert out =~ "this was here"
      # Old-side quote uses the `-` prefix; new-side would be `+`.
      assert out =~ "- a"
      refute out =~ "+ a"
    end

    test "inline comments quote new-side lines with `+` and old-side lines with `-`, whatever the side's type" do
      state = %ReviewState{
        comments: [
          inline_comment(start_line: 1, end_line: 1, side: :new, body: "atom new"),
          inline_comment(start_line: 1, end_line: 1, side: "new", body: "string new"),
          inline_comment(start_line: 2, end_line: 2, side: "old", body: "string old")
        ],
        files: [%{file_name: "x.rs", old_content: "a\nb\nc", new_content: "A\nB\nC"}]
      }

      out = Feedback.format(state, :rejection)

      assert out =~ "x.rs:1 (new)\n    + A\n    > **issue:** atom new"
      assert out =~ "x.rs:1 (new)\n    + A\n    > **issue:** string new"
      assert out =~ "x.rs:2 (old)\n    - b\n    > **issue:** string old"
    end

    test "an inline comment quotes exactly its line range" do
      state = %ReviewState{
        comments: [inline_comment(start_line: 2, end_line: 3, body: "these two")],
        files: [%{file_name: "x.rs", new_content: "one\ntwo\nthree\nfour\nfive"}]
      }

      out = Feedback.format(state, :rejection)

      assert out =~ "x.rs:2-3 (new)\n    + two\n    + three\n    > **issue:** these two"
    end

    test "an inline comment on a file the state no longer lists names it by index" do
      state = %ReviewState{comments: [inline_comment(file_index: 5, body: "gone")]}

      assert Feedback.format(state, :rejection) =~ "\n  file #5:1 (new)\n"
    end

    test "a whitespace-only finding type renders the bare body, unlabelled" do
      state = %ReviewState{global_comments: [comment(body: "plain words", finding_type: "  ")]}

      assert Feedback.format(state, :rejection) =~ "  > plain words\n"
    end

    test "a commit-message comment with no commit message renders without a quote" do
      state = %ReviewState{
        commit_message: nil,
        commit_message_comments: [comment(start_line: 1, end_line: 1, body: "add a body")]
      }

      assert Feedback.format(state, :rejection) =~
               "\n  commit-message:1\n\n    > **issue:** add a body\n"
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
            correct_instructions: false,
            lint_rule: false,
            created_at: Comment.now()
          }
        ]
      }

      out = Feedback.format(state, :rejection)
      assert out =~ "Commit message comments"
      assert out =~ "commit-message:1"
      assert out =~ "rewrite subject"
      # The referenced commit-message line is quoted back under the tag.
      assert out =~ "| subject"
    end

    test "comments on one surface follow each other, a multi-line body indented under its first line" do
      state = %ReviewState{
        files: [%{file_name: "a.ex", new_content: "n1\nn2"}],
        commit_message: "subject",
        comments: [
          inline_comment(body: "one\ntwo"),
          inline_comment(start_line: 2, end_line: 2, body: "three")
        ],
        file_comments: [
          comment(file_index: 0, body: "one\ntwo"),
          comment(file_index: 0, body: "three")
        ],
        global_comments: [comment(body: "one\ntwo"), comment(body: "three")],
        commit_message_comments: [
          comment(start_line: 1, end_line: 1, body: "one\ntwo"),
          comment(start_line: 1, end_line: 1, body: "three")
        ]
      }

      assert Feedback.format(state, :auto) ==
               "\nLine-level comments:\n" <>
                 "\n  a.ex:1 (new)\n    + n1\n    > **issue:** one\n      two\n" <>
                 "\n  a.ex:2 (new)\n    + n2\n    > **issue:** three\n" <>
                 "\nFile-level comments:\n" <>
                 "\n  a.ex\n    > **issue:** one\n      two\n" <>
                 "\n  a.ex\n    > **issue:** three\n" <>
                 "\nGlobal comments:\n" <>
                 "  > **issue:** one\n    two\n" <>
                 "  > **issue:** three\n" <>
                 "\nCommit message comments:\n" <>
                 "\n  commit-message:1\n    | subject\n    > **issue:** one\n      two\n" <>
                 "\n  commit-message:1\n    | subject\n    > **issue:** three\n" <>
                 "\n"
    end

    test "a missing body renders as empty, and a revert without one as restore from HEAD" do
      state = %ReviewState{
        global_comments: [
          comment(body: nil, finding_type: :revert),
          comment(body: nil, finding_type: nil),
          comment(body: nil, finding_type: :issue)
        ]
      }

      assert Feedback.format(state, :auto) ==
               "\nGlobal comments:\n  > **restore from HEAD**\n  > \n  > **issue:** \n\n"
    end

    test "an inline comment quotes nothing from a side that is missing or empty" do
      files = [
        %{file_name: "no-old.ex", new_content: "n"},
        %{file_name: "no-new.ex", old_content: "o"},
        %{file_name: "nil.ex", new_content: nil},
        %{file_name: "empty.ex", new_content: ""}
      ]

      state = %ReviewState{
        files: files,
        comments: [
          inline_comment(file_index: 0, side: :old),
          inline_comment(file_index: 1),
          inline_comment(file_index: 2),
          inline_comment(file_index: 3)
        ]
      }

      assert Feedback.format(state, :auto) ==
               "\nLine-level comments:\n" <>
                 "\n  no-old.ex:1 (old)\n\n    > **issue:** x\n" <>
                 "\n  no-new.ex:1 (new)\n\n    > **issue:** x\n" <>
                 "\n  nil.ex:1 (new)\n\n    > **issue:** x\n" <>
                 "\n  empty.ex:1 (new)\n\n    > **issue:** x\n\n"
    end

    test "a one-character source or commit message is quoted, and a range's trailing empty line is not" do
      state = %ReviewState{
        files: [%{file_name: "x.ex", new_content: "x"}, %{file_name: "t.ex", new_content: "a\n"}],
        commit_message: "x",
        comments: [inline_comment(file_index: 0), inline_comment(file_index: 1, end_line: 2)],
        commit_message_comments: [comment(start_line: 1, end_line: 1)]
      }

      assert Feedback.format(state, :auto) ==
               "\nLine-level comments:\n" <>
                 "\n  x.ex:1 (new)\n    + x\n    > **issue:** x\n" <>
                 "\n  t.ex:1-2 (new)\n    + a\n    > **issue:** x\n" <>
                 "\nCommit message comments:\n" <>
                 "\n  commit-message:1\n    | x\n    > **issue:** x\n\n"
    end

    test "an inline comment's side is named by its text, a nil side included" do
      state = %ReviewState{
        files: [%{file_name: "x.ex", new_content: "n"}],
        comments: [inline_comment(side: nil, finding_type: :question)]
      }

      assert Feedback.questions(state) == [%{location: "x.ex:1 (nil)", question: "x"}]
      assert Feedback.format(state, :auto) =~ "\n  x.ex:1 (nil)\n    + n\n"
    end

    test "inline comment carries file-index + line-range tag" do
      state = %ReviewState{
        comments: [
          inline_comment(file_index: 3, start_line: 10, end_line: 12, body: "tighten")
        ],
        files: [%{}, %{}, %{}, %{file_name: "src/x.rs", new_content: "a\nb\nc\nd\ne\nf"}]
      }

      out = Feedback.format(state, :rejection)
      assert out =~ "src/x.rs:10-12"
      assert out =~ "(new)"
      assert out =~ "tighten"
    end

    test "a comment with no finding_type renders its bare body, unlabelled" do
      # Exercises label_body's defensive `ft_str == ""` branch (nil finding_type).
      state = %ReviewState{
        global_comments: [comment(body: "bare body text", finding_type: nil)]
      }

      out = Feedback.format(state, :rejection)
      assert out =~ "bare body text"
      refute out =~ "**:**"
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

      out = Feedback.format(state, :rejection)
      assert out =~ "restore from HEAD"
    end

    test "revert with a whitespace-only body counts as empty" do
      state = %ReviewState{
        global_comments: [comment(body: "  \n ", finding_type: :revert)]
      }

      out = Feedback.format(state, :rejection)
      assert out =~ "restore from HEAD"
      refute out =~ "**revert:**"
    end

    test "revert WITH a body renders the labelled body, not the synthesised label" do
      state = %ReviewState{
        global_comments: [comment(body: "undo this rename", finding_type: :revert)]
      }

      out = Feedback.format(state, :rejection)
      assert out =~ "**revert:** undo this rename"
      refute out =~ "restore from HEAD"
    end

    test "correct_instructions prints the correct-your-instructions directive" do
      state = %ReviewState{
        global_comments: [comment(body: "fix", correct_instructions: true)]
      }

      out = Feedback.format(state, :rejection)

      assert out =~ """
               > **issue:** fix
               ↳ correct-your-instructions: the reviewer flagged a behavioural
                 issue. Correct the instructions or skills that led to it so
                 future sessions get it right.
             """

      refute out =~ "turn-this-into-a-lint-rule"
    end

    test "lint_rule prints the lint-rule directive" do
      state = %ReviewState{
        global_comments: [comment(body: "fix", lint_rule: true)]
      }

      out = Feedback.format(state, :rejection)

      assert out =~ """
               > **issue:** fix
               ↳ turn-this-into-a-lint-rule: add a lint rule that catches this.
             """

      refute out =~ "correct-your-instructions"
    end

    test "both flags print both directives, indented under the comment on every surface" do
      both = [correct_instructions: true, lint_rule: true]

      state = %ReviewState{
        files: [%{file_name: "a.ex", new_content: "a"}],
        commit_message: "subject",
        comments: [inline_comment(both)],
        file_comments: [comment([file_index: 0] ++ both)],
        global_comments: [comment(both)],
        commit_message_comments: [comment([start_line: 1, end_line: 1] ++ both)]
      }

      out = Feedback.format(state, :rejection)

      directives = fn pad ->
        """
        #{pad}↳ correct-your-instructions: the reviewer flagged a behavioural
        #{pad}  issue. Correct the instructions or skills that led to it so
        #{pad}  future sessions get it right.
        #{pad}↳ turn-this-into-a-lint-rule: add a lint rule that catches this.
        """
      end

      [_framing, sections] = String.split(out, "\n\n\n", parts: 2)

      assert sections ==
               "Line-level comments:\n\n  a.ex:1 (new)\n    + a\n    > **issue:** x\n" <>
                 directives.("    ") <>
                 "\nFile-level comments:\n\n  a.ex\n    > **issue:** x\n" <>
                 directives.("    ") <>
                 "\nGlobal comments:\n  > **issue:** x\n" <>
                 directives.("  ") <>
                 "\nCommit message comments:\n\n  commit-message:1\n    | subject\n" <>
                 "    > **issue:** x\n" <> directives.("    ") <> "\n"
    end
  end

  describe "comment_count" do
    test "empty state has zero comments" do
      assert Feedback.comment_count(%ReviewState{}) == 0
    end

    test "sums comments across all four surfaces" do
      state = %ReviewState{
        comments: [inline_comment([]), inline_comment([])],
        file_comments: [comment(file_index: 0)],
        global_comments: [comment([]), comment([]), comment([])],
        commit_message_comments: [comment(start_line: 1, end_line: 1)]
      }

      assert Feedback.comment_count(state) == 7
    end

    test "counts question comments alongside actionable ones" do
      state = %ReviewState{
        global_comments: [comment(finding_type: :question), comment(finding_type: :issue)]
      }

      assert Feedback.comment_count(state) == 2
    end
  end

  defp comment(overrides) do
    Enum.into(overrides, %{
      id: Comment.new_id(),
      body: "x",
      finding_type: :issue,
      correct_instructions: false,
      lint_rule: false,
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
      correct_instructions: false,
      lint_rule: false,
      created_at: Comment.now()
    })
  end
end
