defmodule Meerkat.PendingAnswersTest do
  use ExUnit.Case, async: true

  alias Meerkat.PendingAnswers

  setup do
    repo = Meerkat.TestHelpers.make_tmp_repo("meerkat-pending-answers-test")
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, repo: repo}
  end

  describe "version/0" do
    test "matches the @version attribute (1)" do
      assert PendingAnswers.version() == 1
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
