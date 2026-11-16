defmodule Meerkat.PendingAnswersTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO, only: [with_io: 2]

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

  # One git repo for the save/2 tests, which remove what they wrote.
  setup_all do
    repo =
      Meerkat.TestHelpers.fixture_template("meerkat-pending-answers-save", fn dir ->
        Meerkat.TestHelpers.git(dir, ["init", "-q"])
      end)

    {:ok, git_repo: repo}
  end

  describe "save/2" do
    setup %{git_repo: repo} do
      on_exit(fn ->
        File.rm_rf!(Path.dirname(PendingAnswers.path_for(repo)))
        File.rm_rf!(Path.join(repo, "lib"))
      end)
    end

    test "stores a v1 file with a createdAt stamp that load/1 reads back", %{git_repo: repo} do
      assert {:ok, 1} = PendingAnswers.save(repo, @valid_input)

      assert %{version: 1, created_at: created_at, answers: answers} = PendingAnswers.load(repo)
      assert [%{location: "src/foo.rs:42", question: "why?", answer: "because"}] == answers
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(created_at)

      assert %{"version" => 1, "createdAt" => ^created_at} =
               repo |> PendingAnswers.path_for() |> File.read!() |> Jason.decode!()
    end

    test "a save from a subdirectory stores the repo's file", %{git_repo: repo} do
      subdir = Path.join(repo, "lib/nested")
      File.mkdir_p!(subdir)

      assert {:ok, 1} = PendingAnswers.save(subdir, @valid_input)
      assert %{answers: [%{question: "why?"}]} = PendingAnswers.load(repo)
      refute File.exists?(Path.join(subdir, ".git"))
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
      assert %{answers: [%{location: "a"}, %{location: "b"}]} = PendingAnswers.load(repo)
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
        assert {:error, :invalid_input, message} = PendingAnswers.save(repo, unquote(input))
        assert is_binary(message) and message != ""
        refute File.exists?(PendingAnswers.path_for(repo))
      end
    end

    test "names the first invalid answer by its index", %{git_repo: repo} do
      input = ~s({"answers": [{"location": "a", "question": "q", "answer": "a"}, {}]})

      assert PendingAnswers.save(repo, input) ==
               {:error, :invalid_input,
                ~s(answers[1] must have string "location", "question" and "answer")}
    end

    test "a rejected input leaves the earlier file untouched", %{git_repo: repo} do
      assert {:ok, 1} = PendingAnswers.save(repo, @valid_input)
      before = File.read!(PendingAnswers.path_for(repo))

      assert {:error, :invalid_input, _} = PendingAnswers.save(repo, ~s({"answers": []}))
      assert File.read!(PendingAnswers.path_for(repo)) == before
    end

    test "reports a write failure instead of raising", %{git_repo: repo} do
      File.write!(Path.dirname(PendingAnswers.path_for(repo)), "a file, not a directory")

      assert {:error, :write_failed, message} = PendingAnswers.save(repo, @valid_input)
      assert message =~ "couldn't write"
    end

    test "refuses a directory that is not a git repository", %{repo: not_a_repo} do
      assert {:error, :not_a_repo, message} = PendingAnswers.save(not_a_repo, @valid_input)
      assert message =~ ~r/^not a git repository: ./
      refute File.exists?(PendingAnswers.path_for(not_a_repo))
    end
  end

  describe "parse/1" do
    test "keeps every answer, in order, with only its three fields" do
      input =
        Jason.encode!(%{
          "answers" => [
            %{"location" => "a", "question" => "q1", "answer" => "a1", "extra" => 1},
            %{"location" => "b", "question" => "q2", "answer" => "a2"}
          ]
        })

      assert PendingAnswers.parse(input) ==
               {:ok,
                [
                  %{"location" => "a", "question" => "q1", "answer" => "a1"},
                  %{"location" => "b", "question" => "q2", "answer" => "a2"}
                ]}
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
      test "rejects #{label}" do
        assert {:error, :invalid_input, message} = PendingAnswers.parse(unquote(input))
        assert is_binary(message) and message != ""
      end
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

    test "an unreadable file returns nil and warns", %{repo: repo} do
      path = PendingAnswers.path_for(repo)
      File.mkdir_p!(path)

      {result, stderr} = with_io(:stderr, fn -> PendingAnswers.load(repo) end)

      assert result == nil
      assert stderr =~ "meerkat: warning — couldn't read pending-answers at #{path}: :eisdir"
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

      {result, stderr} = with_io(:stderr, fn -> PendingAnswers.load(repo) end)

      assert result == nil

      assert stderr =~
               "pending-answers at #{path} unusable (schema mismatch (expected version 1))"

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
      {:error, err} = Jason.decode("not json at all")

      {result, stderr} = with_io(:stderr, fn -> PendingAnswers.load(repo) end)

      assert result == nil
      assert stderr =~ "unusable (JSON parse failed: #{Exception.message(err)})"
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

    test "a file that cannot be deleted still returns :ok and warns", %{repo: repo} do
      path = PendingAnswers.path_for(repo)
      File.mkdir_p!(path)

      {result, stderr} = with_io(:stderr, fn -> PendingAnswers.clear(repo) end)

      assert result == :ok

      assert stderr =~
               ~r/meerkat: warning — couldn't delete pending-answers at #{Regex.escape(path)}: :\w+\. Banner may reappear on the next review\./
    end
  end
end
