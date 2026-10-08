defmodule MeerkatWeb.ReviewQuestionsTest do
  use MeerkatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Meerkat.TestHelpers
  alias Meerkat.{Decision, Feedback, PendingAnswers, PendingQuestions, ReviewServer, ReviewState}
  alias MeerkatWeb.ReviewLive

  setup do
    isolate_git_config()
    repo = make_git_repo("meerkat-question-rounds")

    git(repo, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=t@t.t",
      "commit",
      "--allow-empty",
      "-qm",
      "initial"
    ])

    stage(repo, "src/x.ex", "defmodule X do\nend\n")
    {:ok, state} = ReviewState.from_target({:staged, nil}, repo)
    rid = "questions-#{System.unique_integer([:positive])}"

    previous =
      for key <- [:repo_path, :review_id, :review_state],
          do: {key, Application.fetch_env(:meerkat, key)}

    Application.put_env(:meerkat, :repo_path, repo)
    Application.put_env(:meerkat, :review_id, rid)
    Application.put_env(:meerkat, :review_state, state)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Meerkat.ReviewRegistry, rid),
          do: DynamicSupervisor.terminate_child(Meerkat.ReviewServerSup, pid)

      for {key, value} <- previous do
        case value do
          {:ok, val} -> Application.put_env(:meerkat, key, val)
          :error -> Application.delete_env(:meerkat, key)
        end
      end

      File.rm_rf!(repo)
    end)

    {:ok, repo: repo, rid: rid}
  end

  for {event, tag} <- [{"decision.reject", :reject}, {"decision.approve", :approve_with_feedback}] do
    test "#{event} records the questions and the next round pins every answer", %{
      conn: conn,
      repo: repo,
      rid: rid
    } do
      {:ok, view, _} = live_isolated(conn, ReviewLive)
      {:ok, other, _} = live_isolated(conn, ReviewLive)
      # Both views predate both saves; each makes a different change.
      view |> element("button[phx-click='comment_form.show_global']") |> render_click()
      submit(view, "global", "Why **this**?")
      other |> element("#file-0 button", "+ Add file comment") |> render_click()
      submit(other, "file:0", "Why this file?")
      {:ok, reloaded, _} = live_isolated(conn, ReviewLive)
      assert render(reloaded) =~ "Why this file?"
      assert render(reloaded) =~ "Why <strong>this</strong>?"
      questions = ReviewServer.get_state(rid) |> Feedback.questions()
      assert length(questions) == 2

      render_click(reloaded, unquote(event), %{})
      assert {unquote(tag), payload} = Decision.current()
      assert payload =~ "answer 2 questions"
      assert {:ok, ^questions} = PendingQuestions.unanswered(repo)
      :ok = ReviewServer.delete_snapshot(repo, rid)
      [{pid, _}] = Registry.lookup(Meerkat.ReviewRegistry, rid)
      :ok = DynamicSupervisor.terminate_child(Meerkat.ReviewServerSup, pid)
      Decision.reset()
      assert {:ok, ^questions} = PendingQuestions.unanswered(repo)

      answers = Enum.map(questions, &Map.put(&1, :answer, "Because **it matters**."))
      assert {:ok, 2} = PendingAnswers.save(repo, Jason.encode!(%{answers: answers}))
      assert {:ok, []} = PendingQuestions.unanswered(repo)
      {:ok, next, _} = live_isolated(conn, ReviewLive)
      assert has_element?(next, "section.pending-answers h2", "Pending answers (2)")
      assert has_element?(next, "section.pending-answers .question strong", "this")
      assert has_element?(next, "section.pending-answers .answer strong", "it matters")
      refute has_element?(next, ".global-comments .note")
      render_click(next, "decision.approve", %{})
      assert {:ok, []} = PendingQuestions.unanswered(repo)
      refute PendingAnswers.load(repo)
    end
  end

  test "Cancel wipes questions and owes nothing after restart", %{
    conn: conn,
    repo: repo,
    rid: rid
  } do
    {:ok, view, _} = live_isolated(conn, ReviewLive)
    view |> element("button[phx-click='comment_form.show_global']") |> render_click()
    submit(view, "global", "Never delivered?")
    render_click(view, "decision.cancel", %{})
    assert {:cancel, ""} = Decision.current()
    assert ReviewServer.get_state(rid).global_comments == []
    assert {:ok, []} = PendingQuestions.unanswered(repo)
    :ok = ReviewServer.delete_snapshot(repo, rid)
    Decision.reset()
    assert {:ok, []} = PendingQuestions.unanswered(repo)
  end

  defp submit(view, form_key, body) do
    render_hook(view, "comment.submit", %{
      "form_key" => form_key,
      "body" => body,
      "finding_type" => "question",
      "learn_from_this" => false
    })
  end
end
