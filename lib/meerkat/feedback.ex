defmodule Meerkat.Feedback do
  @moduledoc """
  Render a `%ReviewState{}`'s comments as a stderr-friendly string —
  one block per comment, surface and finding-type prefixed, body
  in-line. The shell that ran `meerkat --commit-msg` sees this on
  stderr as first-party feedback to the agent that drove the commit.

  When any comment is `:question`, the formatted output is prefixed
  with a directive block telling the agent how to write
  `pending-answers.json` — the file meerkat reads on the next
  invocation to surface a banner above the diff so the human reviewer
  sees the answers in context.
  """

  alias Meerkat.{PendingAnswers, ReviewState}

  @doc """
  Build the feedback string. `repo_path` is used to resolve the
  pending-answers file path included in the question directive (only
  emitted when at least one comment is `:question`). Returns `""`
  when there's nothing to surface — the CLI's empty-string branch
  prints the bare success message instead.
  """
  @spec format(ReviewState.t(), String.t() | nil) :: String.t()
  def format(state, repo_path \\ nil), do: format(state, repo_path, :auto)

  @doc """
  Same as `format/2` but takes an explicit `mode` (`:rejection`,
  `:approval_with_feedback`, or `:auto`) so the framing header
  matches the decision the reviewer made. `:auto` keeps the older
  zero-header behaviour for callers that don't know.

  - `:rejection` — "user reviewed your commit and wants changes..."
  - `:approval_with_feedback` — "user approved but also left
    comments..." (returns `""` when there are no comments — an
    approval-without-comments needs no stderr noise).
  """
  @spec format(ReviewState.t(), String.t() | nil, :auto | :rejection | :approval_with_feedback) ::
          String.t()
  def format(%ReviewState{} = state, repo_path, mode) do
    parts =
      [
        render_inline(state),
        render_file(state),
        render_global(state),
        render_commit_msg(state)
      ]
      |> Enum.reject(&(&1 == ""))

    case {parts, mode} do
      {[], :approval_with_feedback} ->
        ""

      {[], _} ->
        ""

      {blocks, _} ->
        framing = framing_header(mode)
        action_summary = action_summary(state)
        directive = if has_questions?(state), do: question_directive(repo_path), else: ""
        framing <> action_summary <> directive <> Enum.join(blocks, "") <> "\n"
    end
  end

  defp framing_header(:rejection) do
    """
    The user reviewed your commit and wants changes before it lands. The comments below are direct instructions from them — treat them as first-party feedback, not a third-party verdict.

    """
  end

  defp framing_header(:approval_with_feedback) do
    """
    The user approved the commit but also left comments. These are direct instructions from them — apply them to your next commit or follow-up. Treat them as first-party feedback, not a third-party verdict.

    """
  end

  defp framing_header(_), do: ""

  # Action-first summary at the very top — a skimming reader sees the
  # to-do list before the JSON walkthrough. Lists what needs DOING vs
  # what needs ANSWERING so a question doesn't get mistaken for a fix
  # request.
  defp action_summary(%ReviewState{} = state) do
    all = all_comments(state)

    {questions, actionable} =
      Enum.split_with(all, &(&1.finding_type == :question))

    case {questions, actionable} do
      {[], _} ->
        ""

      {qs, []} ->
        """
        ▶ ACTION: answer #{length(qs)} question#{plural(qs)} — see the directive below. No code changes; the comments are #{Enum.join(answer_labels(qs), ", ")}.

        """

      {qs, acs} ->
        """
        ▶ ACTION:
          1. Answer #{length(qs)} question#{plural(qs)} (see directive below) — analysis only, no code edits for these.
          2. Address #{length(acs)} feedback comment#{plural(acs)} below (#{summary_kinds(acs)}) — code changes as usual.

        """
    end
  end

  defp plural(list) when length(list) == 1, do: ""
  defp plural(_), do: "s"

  defp summary_kinds(items) do
    items
    |> Enum.frequencies_by(& &1.finding_type)
    |> Enum.map_join(", ", fn {kind, n} -> "#{n} #{kind}" end)
  end

  # Short location-style label per question, for the top-of-output
  # summary. Mirrors the per-comment formatters' surface tag so the
  # reader can find the matching block below.
  defp answer_labels(questions) do
    questions
    |> Enum.map(fn
      %{file_index: idx, side: side, start_line: s, end_line: e} ->
        "inline file ##{idx} #{side} L#{s}-#{e}"

      %{file_index: idx} ->
        "file ##{idx}"

      %{start_line: s, end_line: e} ->
        "commit-msg L#{s}-#{e}"

      _ ->
        "global"
    end)
  end

  @doc """
  True when any comment in `state` carries `finding_type: :question`.
  Triggers the question directive prelude in `format/2`.
  """
  @spec has_questions?(ReviewState.t()) :: boolean()
  def has_questions?(%ReviewState{} = state) do
    Enum.any?(all_comments(state), &(&1.finding_type == :question))
  end

  @doc "Total number of comments across all four surfaces (inline, file, global, commit-message)."
  @spec comment_count(ReviewState.t()) :: non_neg_integer()
  def comment_count(%ReviewState{} = state), do: length(all_comments(state))

  defp all_comments(%ReviewState{} = state) do
    state.comments ++
      state.file_comments ++ state.global_comments ++ state.commit_message_comments
  end

  # Directive prepended to feedback when at least one comment is
  # :question. Tells the agent to answer with analysis (not code) and
  # where to write the JSON answers file so meerkat can pin them on
  # the next review.
  defp question_directive(repo_path) do
    path =
      case repo_path do
        nil -> "<gitdir>/meerkat-precommit/pending-answers.json"
        rp -> PendingAnswers.path_for(rp)
      end

    version = PendingAnswers.version()

    """

    ⚠ This feedback contains **question**-type comments. Answer them with analysis — \
    do NOT modify code in response. (Non-question comments — issue / suggestion / revert / \
    follow-up — still apply, change code for those as usual.)

    Write your answers as JSON to:
      #{path}

    Schema (overwrite the file if it already exists):
      {
        "version": #{version},
        "createdAt": "<ISO-8601 UTC, e.g. 2026-04-25T12:34:56Z>",
        "answers": [
          {
            "location": "<human-readable origin of the question — we suggest 'src/foo.rs:42 (new)' for a line comment, 'file: src/foo.rs' for a file-level comment, or 'global' — rendered as-is in the UI>",
            "question": "<verbatim body of the **question:** comment>",
            "answer": "<your answer, markdown OK>"
          }
        ]
      }

    Trigger a new meerkat review so the reviewer sees your answers:
      • If you also have code changes to make, apply them and re-run `git commit` — the pre-commit hook reopens meerkat, which pins your answers above the diff.
      • If there are no code changes to make, run `meerkat` (no args) from this repo — it reopens the review on the current staged diff with your answers pinned above it.

    """
  end

  # ---------------------------------------------------------------------
  # Section renderers. Per comment: file path + line range as the
  # primary key, side-arrow-prefixed source content quoted under it,
  # Conventional-Comments-style `**type:** body` line, then the
  # learn-from-this directive if set. Surface order: line-level first
  # (most-anchored), then file-level, then global, then commit-msg.
  # ---------------------------------------------------------------------

  defp render_inline(%ReviewState{comments: []}), do: ""

  defp render_inline(%ReviewState{} = state) do
    body =
      Enum.map_join(state.comments, "", fn c ->
        path = file_name_for(state, c.file_index)
        arrow = if c.side == "old" or c.side == :old, do: "-", else: "+"
        range = line_range(c.start_line, c.end_line)
        quoted = quote_content(extract_lines(state, c), arrow)
        labelled = label_body(c.finding_type, c.body)
        body = indent_body(labelled, "      ")
        learn = learn_line(c.learn_from_this, "    ")
        reminder = q_reminder(c)

        "\n  #{path}:#{range} (#{side_str(c.side)})\n#{quoted}\n    > #{body}#{reminder}\n#{learn}"
      end)

    "\nLine-level comments:\n#{body}"
  end

  defp render_file(%ReviewState{file_comments: []}), do: ""

  defp render_file(%ReviewState{} = state) do
    body =
      Enum.map_join(state.file_comments, "", fn fc ->
        path = file_name_for(state, fc.file_index)
        labelled = label_body(fc.finding_type, fc.body)
        body = indent_body(labelled, "      ")
        learn = learn_line(fc.learn_from_this, "    ")
        reminder = q_reminder(fc)

        "\n  #{path}\n    > #{body}#{reminder}\n#{learn}"
      end)

    "\nFile-level comments:\n#{body}"
  end

  defp render_global(%ReviewState{global_comments: []}), do: ""

  defp render_global(%ReviewState{} = state) do
    body =
      Enum.map_join(state.global_comments, "", fn gc ->
        labelled = label_body(gc.finding_type, gc.body)
        body = indent_body(labelled, "    ")
        learn = learn_line(gc.learn_from_this, "  ")
        reminder = q_reminder(gc)

        "  > #{body}#{reminder}\n#{learn}"
      end)

    "\nGlobal comments:\n#{body}"
  end

  defp render_commit_msg(%ReviewState{commit_message_comments: []}), do: ""

  defp render_commit_msg(%ReviewState{} = state) do
    body =
      Enum.map_join(state.commit_message_comments, "", fn cmc ->
        range = line_range(cmc.start_line, cmc.end_line)
        quoted = quote_content(extract_commit_msg_lines(state, cmc), "|")
        labelled = label_body(cmc.finding_type, cmc.body)
        body = indent_body(labelled, "      ")
        learn = learn_line(cmc.learn_from_this, "    ")
        reminder = q_reminder(cmc)

        "\n  commit-message:#{range}\n#{quoted}\n    > #{body}#{reminder}\n#{learn}"
      end)

    "\nCommit message comments:\n#{body}"
  end

  # ---------------------------------------------------------------------
  # Helpers — labelling, content quoting, learn line.
  # ---------------------------------------------------------------------

  defp file_name_for(state, idx) do
    case Enum.at(state.files, idx) do
      %{file_name: name} -> name
      _ -> "file ##{idx}"
    end
  end

  defp line_range(s, e) when s == e, do: "#{s}"
  defp line_range(s, e), do: "#{s}-#{e}"

  defp side_str(side) when is_atom(side), do: Atom.to_string(side)
  defp side_str(side), do: side

  # Conventional Comments labelling. Empty-body revert becomes a
  # stand-alone sentence; other empty bodies fall through to the
  # labelled form (the UI normally prevents that case).
  defp label_body(ft, body) do
    ft_str = ft |> to_string() |> String.trim()
    body_trim = (body || "") |> String.trim()

    cond do
      ft_str == "" -> body || ""
      body_trim == "" and ft_str == "revert" -> "**restore from HEAD**"
      true -> "**#{ft_str}:** #{body || ""}"
    end
  end

  defp extract_lines(state, c) do
    file = Enum.at(state.files, c.file_index) || %{}

    source =
      case to_string(c.side) do
        "old" -> Map.get(file, :old_content, "")
        _ -> Map.get(file, :new_content, "")
      end

    case source do
      nil ->
        ""

      "" ->
        ""

      str ->
        str
        |> String.split("\n")
        |> Enum.slice((c.start_line - 1)..(c.end_line - 1))
        |> Enum.join("\n")
    end
  end

  defp extract_commit_msg_lines(%ReviewState{commit_message: msg}, cmc) do
    if is_binary(msg) and msg != "" do
      msg
      |> String.split("\n")
      |> Enum.slice((cmc.start_line - 1)..(cmc.end_line - 1))
      |> Enum.join("\n")
    else
      ""
    end
  end

  defp quote_content("", _prefix), do: ""

  defp quote_content(text, prefix) do
    text
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map_join("\n", &"    #{prefix} #{&1}")
  end

  defp indent_body(body, pad) do
    body
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map_join("\n", fn
      {l, 0} -> l
      {l, _} -> pad <> l
    end)
  end

  # Per-comment "please learn from this" directive. Off → "". On →
  # three-line block telling the agent which channel to use (memory /
  # skill / review-agent prompt) so the next session inherits the
  # learning. Indented by `pad` to align with the comment block above.
  defp learn_line(false, _pad), do: ""
  defp learn_line(nil, _pad), do: ""

  defp learn_line(true, pad) do
    """
    #{pad}↳ please-learn-from-this: the reviewer flagged this comment as worth
    #{pad}  internalising. Persist the lesson in whichever channel fits — a
    #{pad}  memory file, a skill update, or a review-agent prompt tweak — so
    #{pad}  future sessions land it without being told again.
    """
  end

  # One-line reminder appended to every :question comment so a skim-
  # reader can't mistake it for an action item. Matches the /question
  # skill's framing: read-only investigation + direct answer, zero
  # code changes triggered by THIS comment.
  defp q_reminder(%{finding_type: :question}),
    do: "\n      ↳ question — answer with analysis only. Do NOT edit code for this comment."

  defp q_reminder(%{finding_type: "question"}),
    do: "\n      ↳ question — answer with analysis only. Do NOT edit code for this comment."

  defp q_reminder(_), do: ""
end
