defmodule Meerkat.PendingAnswersTest do
  use ExUnit.Case, async: true

  alias Meerkat.PendingAnswers

  setup do
    repo = Meerkat.TestHelpers.make_tmp_repo("meerkat-pending-answers-test")
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, repo: repo}
  end

  @valid_input Jason.encode!(%{
                 "answers" => [
                   %{"location" => "src/foo.rs:42", "question" => "why?", "answer" => "because"}
                 ]
               })

  describe "save/2" do
    setup do
      repo = Meerkat.TestHelpers.make_git_repo("meerkat-pending-answers-save")
      on_exit(fn -> File.rm_rf!(repo) end)
      {:ok, git_repo: repo}
    end

    test "stores a v1 file with a createdAt stamp that load/1 reads back", %{git_repo: repo} do
      assert {:ok, 1} = PendingAnswers.save(repo, @valid_input)

      assert %{version: 1, created_at: created_at, answers: answers} = PendingAnswers.load(repo)
      assert [%{location: "src/foo.rs:42", question: "why?", answer: "because"}] == answers
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(created_at)

      assert %{"version" => 1, "createdAt" => ^created_at} =
               repo |> PendingAnswers.path_for() |> File.read!() |> Jason.decode!()
    end

    test "counts every answer and keeps their order", %{git_repo: repo} do
      input =
        Jason.encode!(%{
          "answers" => [
            %{"location" => "a", "question" => "q1", "answer" => "a1"},
            %{"location" => "b", "question" => "q2", "answer" => "a2"}
          ]
        })

      assert {:ok, 2} = PendingAnswers.save(repo, input)
      assert %{answers: [%{question: "q1"}, %{question: "q2"}]} = PendingAnswers.load(repo)
    end

    test "a repeated save overwrites the earlier answers", %{git_repo: repo} do
      assert {:ok, 1} = PendingAnswers.save(repo, @valid_input)

      second =
        Jason.encode!(%{
          "answers" => [%{"location" => "global", "question" => "q2", "answer" => "a2"}]
        })

      assert {:ok, 1} = PendingAnswers.save(repo, second)

      assert %{answers: [%{location: "global", question: "q2", answer: "a2"}]} =
               PendingAnswers.load(repo)
    end

    for {label, input} <- [
          {"invalid JSON", "not json"},
          {"a JSON array", "[]"},
          {"an object without answers", ~s({"other": 1})},
          {"answers that is not a list", ~s({"answers": "x"})},
          {"an empty answers list", ~s({"answers": []})},
          {"an answer missing a field", ~s({"answers": [{"location": "a", "question": "q"}]})},
          {"an answer with a non-string answer",
           ~s({"answers": [{"location": "a", "question": "q", "answer": 1}]})},
          {"an answer with a non-string location",
           ~s({"answers": [{"location": 1, "question": "q", "answer": "a"}]})},
          {"an answer with a non-string question",
           ~s({"answers": [{"location": "a", "question": 1, "answer": "a"}]})},
          {"an answer that is not an object", ~s({"answers": ["a"]})}
        ] do
      test "rejects #{label} and writes nothing", %{git_repo: repo} do
        assert {:error, message} = PendingAnswers.save(repo, unquote(input))
        assert is_binary(message) and message != ""
        refute File.exists?(PendingAnswers.path_for(repo))
      end
    end

    test "a rejected input leaves the earlier file untouched", %{git_repo: repo} do
      assert {:ok, 1} = PendingAnswers.save(repo, @valid_input)
      before = File.read!(PendingAnswers.path_for(repo))

      assert {:error, _} = PendingAnswers.save(repo, ~s({"answers": []}))
      assert File.read!(PendingAnswers.path_for(repo)) == before
    end

    test "reports a write failure instead of raising", %{git_repo: repo} do
      File.write!(Path.dirname(PendingAnswers.path_for(repo)), "a file, not a directory")

      assert {:error, message} = PendingAnswers.save(repo, @valid_input)
      assert message =~ "couldn't write"
    end

    test "refuses a directory that is not a git repository", %{repo: not_a_repo} do
      assert {:error, message} = PendingAnswers.save(not_a_repo, @valid_input)
      assert message =~ "not a git repository"
      refute File.exists?(PendingAnswers.path_for(not_a_repo))
    end
  end

  describe "load/1 — happy path" do
    test "well-formed file decodes into the answers list", %{repo: repo} do
      path = PendingAnswers.path_for(repo)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "createdAt" => "2026-05-14T00:00:00Z",
          "answers" => [
            %{
              "location" => "src/foo.rs:42",
              "question" => "why this?",
              "answer" => "because"
            }
          ]
        })
      )

      assert %{
               version: 1,
               created_at: "2026-05-14T00:00:00Z",
               answers: [
                 %{location: "src/foo.rs:42", question: "why this?", answer: "because"}
               ]
             } = PendingAnswers.load(repo)
    end

    test "malformed individual answer entries are silently dropped", %{repo: repo} do
      path = PendingAnswers.path_for(repo)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "createdAt" => "2026-05-14T00:00:00Z",
          "answers" => [
            %{"location" => "a", "question" => "q1", "answer" => "a1"},
            %{"broken" => "entry"},
            %{"location" => "b", "question" => "q2", "answer" => "a2"}
          ]
        })
      )

      assert %{answers: [%{question: "q1"}, %{question: "q2"}]} = PendingAnswers.load(repo)
    end
  end

  describe "load/1 — empty cases" do
    test "missing file returns nil", %{repo: repo} do
      assert PendingAnswers.load(repo) == nil
    end

    test "empty answers list returns nil", %{repo: repo} do
      path = PendingAnswers.path_for(repo)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{"version" => 1, "createdAt" => "now", "answers" => []})
      )

      assert PendingAnswers.load(repo) == nil
      assert File.exists?(path)
    end
  end

  describe "load/1 — quarantine paths" do
    test "wrong version → quarantine + nil", %{repo: repo} do
      path = PendingAnswers.path_for(repo)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{"version" => 999, "answers" => [], "createdAt" => "x"})
      )

      assert PendingAnswers.load(repo) == nil
      refute File.exists?(path)
      # The bad file is renamed to .corrupt.<ts>, so something in the
      # parent dir starts with the original filename + ".corrupt.".
      base = Path.basename(path)

      assert File.ls!(Path.dirname(path))
             |> Enum.any?(&String.starts_with?(&1, base <> ".corrupt."))
    end

    test "malformed JSON → quarantine + nil", %{repo: repo} do
      path = PendingAnswers.path_for(repo)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json at all")

      assert PendingAnswers.load(repo) == nil
      refute File.exists?(path)
    end
  end

  describe "clear/1" do
    test "removes the file", %{repo: repo} do
      path = PendingAnswers.path_for(repo)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "anything")

      assert :ok = PendingAnswers.clear(repo)
      refute File.exists?(path)
    end

    test "no-op when file is missing", %{repo: repo} do
      assert :ok = PendingAnswers.clear(repo)
    end
  end
end
