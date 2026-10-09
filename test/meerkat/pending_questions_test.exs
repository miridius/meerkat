defmodule Meerkat.PendingQuestionsTest do
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers
  alias Meerkat.{PendingAnswers, PendingQuestions}

  setup do
    isolate_git_config()
    repo = make_git_repo("meerkat-owed-questions")
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, repo: repo}
  end

  @questions [
    %{location: "src/x.rs:3 (new)", question: "why?"},
    %{location: "file: src/x.rs", question: "why?"}
  ]

  test "obligations survive repeated reads and replacing the pending answer set", %{repo: repo} do
    assert {:ok, []} = PendingQuestions.unanswered(repo)
    assert :ok = PendingQuestions.replace(repo, @questions)
    assert {:ok, @questions} = PendingQuestions.unanswered(repo)
    assert {:ok, @questions} = PendingQuestions.unanswered(repo)

    assert {:ok, 1} = PendingAnswers.save(repo, answers([hd(@questions)]))
    assert {:ok, [List.last(@questions)]} == PendingQuestions.unanswered(repo)

    assert {:ok, 2} = PendingAnswers.save(repo, answers(@questions))
    assert {:ok, []} = PendingQuestions.unanswered(repo)
    # Merely passing the gate must not erase the obligation or banner.
    assert File.exists?(PendingQuestions.path_for(repo))
    assert length(PendingAnswers.load(repo).answers) == 2

    PendingAnswers.clear(repo)
    assert {:ok, @questions} = PendingQuestions.unanswered(repo)
  end

  test "obligations persist at the stable filename with the versioned schema", %{repo: repo} do
    # Git resolves the physical root even when TMPDIR or the caller is symlinked.
    canonical_repo = git(repo, ["rev-parse", "--show-toplevel"])
    path = Path.join([canonical_repo, ".git", "meerkat-precommit", "pending-questions.json"])
    linked_repo = repo <> "-alias"
    File.ln_s!(repo, linked_repo)
    on_exit(fn -> File.rm!(linked_repo) end)

    for repo_path <- [repo, linked_repo] do
      assert PendingQuestions.path_for(repo_path) == path
      assert :ok = PendingQuestions.replace(repo_path, @questions)

      assert Jason.decode!(File.read!(path)) == %{
               "version" => 1,
               "questions" => [
                 %{"location" => "src/x.rs:3 (new)", "question" => "why?"},
                 %{"location" => "file: src/x.rs", "question" => "why?"}
               ]
             }
    end
  end

  test "a later round replaces the prior obligations, including a round owing nothing", %{
    repo: repo
  } do
    :ok = PendingQuestions.replace(repo, @questions)
    next = [%{location: "global", question: "what next?"}]
    assert :ok = PendingQuestions.replace(repo, next)
    assert {:ok, ^next} = PendingQuestions.unanswered(repo)
    assert :ok = PendingQuestions.replace(repo, [])
    assert {:ok, []} = PendingQuestions.unanswered(repo)
  end

  test "wrong locations, edited question bodies, and blank answers cannot discharge a question",
       %{repo: repo} do
    :ok = PendingQuestions.replace(repo, @questions)

    for answer <- [
          %{location: "global", question: "why?", answer: "because"},
          %{location: "src/x.rs:3 (new)", question: "why", answer: "because"},
          %{location: "src/x.rs:3 (new)", question: "why?", answer: " \n\t "}
        ] do
      assert {:ok, 1} = PendingAnswers.save(repo, Jason.encode!(%{answers: [answer]}))
      assert {:ok, @questions} = PendingQuestions.unanswered(repo)
    end
  end

  test "a malformed answer file cannot satisfy an obligation", %{repo: repo} do
    :ok = PendingQuestions.replace(repo, @questions)

    File.write!(
      PendingAnswers.path_for(repo),
      Jason.encode!(%{
        version: 1,
        createdAt: "now",
        answers: [%{location: "src/x.rs:3 (new)", question: "why?", answer: 1}]
      })
    )

    assert {:ok, @questions} = PendingQuestions.unanswered(repo)
  end

  test "unreadable or malformed obligations fail closed and are not discarded", %{repo: repo} do
    path = PendingQuestions.path_for(repo)
    File.mkdir_p!(Path.dirname(path))

    malformed = "#{path} is not a version-1 owed-questions file"

    for {content, reason} <- [
          {"not JSON", "#{path} is not valid JSON"},
          {"[]", malformed},
          {~s({"version":2,"questions":[]}), malformed},
          {~s({"version":1,"questions":"not a list"}), malformed},
          {~s({"version":1,"questions":[{}]}), malformed},
          {~s({"version":1,"questions":[{"location":1,"question":"why?"}]}), malformed},
          {~s({"version":1,"questions":[{"location":"global","question":1}]}), malformed}
        ] do
      File.write!(path, content)
      assert {:error, ^reason} = PendingQuestions.unanswered(repo)
      assert File.read!(path) == content
    end

    File.rm!(path)
    File.mkdir!(path)
    reason = "#{path}: illegal operation on a directory"
    assert {:error, ^reason} = PendingQuestions.unanswered(repo)
  end

  test "an explicitly empty obligation file is harmless, but failure to clear it is not", %{
    repo: repo
  } do
    path = PendingQuestions.path_for(repo)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"version":1,"questions":[]}))
    assert {:ok, []} = PendingQuestions.unanswered(repo)
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, reason} = File.rm(path)
    error = assert_raise File.Error, fn -> PendingQuestions.replace(repo, []) end
    assert error.action == "clear owed questions"
    assert error.path == path
    assert error.reason == reason
    assert File.dir?(path)
  end

  test "failure to persist is not treated as successful feedback", %{repo: repo} do
    File.write!(Path.dirname(PendingQuestions.path_for(repo)), "not a directory")
    assert_raise MatchError, fn -> PendingQuestions.replace(repo, @questions) end
  end

  test "obligations follow the worktree across branches and subdirectories, not other worktrees",
       %{repo: repo} do
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

    :ok = PendingQuestions.replace(repo, @questions)
    git(repo, ["switch", "-qc", "another-branch"])
    subdir = Path.join(repo, "src")
    File.mkdir_p!(subdir)
    assert PendingQuestions.path_for(subdir) == PendingQuestions.path_for(repo)
    assert {:ok, @questions} = PendingQuestions.unanswered(subdir)

    worktree = Path.join(repo, "other-worktree")
    git(repo, ["worktree", "add", "-qb", "other", worktree])
    refute PendingQuestions.path_for(worktree) == PendingQuestions.path_for(repo)
    assert {:ok, []} = PendingQuestions.unanswered(worktree)
    :ok = PendingQuestions.replace(worktree, [%{location: "global", question: "other?"}])
    assert {:ok, @questions} = PendingQuestions.unanswered(repo)
  end

  defp answers(questions) do
    Jason.encode!(%{answers: Enum.map(questions, &Map.put(&1, :answer, "Because **this**."))})
  end
end
