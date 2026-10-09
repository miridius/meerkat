defmodule Meerkat.PendingQuestions do
  @moduledoc """
  Durable, per-worktree questions owed after feedback. Kept separately from
  the in-progress snapshot and pending answers, so replacing an answer set
  cannot silently forgive a question. Unreadable obligations fail closed.
  """

  alias Meerkat.{AtomicFile, Git, PendingAnswers}

  @type question :: %{location: String.t(), question: String.t()}

  @doc "Replace the last round's obligations before publishing its feedback."
  @spec replace(String.t(), [question()]) :: :ok
  def replace(repo_path, []) do
    case File.rm(path_for(repo_path)) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "clear owed questions",
          path: path_for(repo_path)
    end
  end

  def replace(repo_path, questions) do
    payload = %{version: 1, questions: questions}

    case AtomicFile.write(path_for(repo_path), Jason.encode!(payload)) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "record owed questions",
          path: path_for(repo_path)
    end
  end

  @doc "Return only questions without a matching, nonblank pending answer."
  @spec unanswered(String.t()) :: {:ok, [question()]} | {:error, String.t()}
  def unanswered(repo_path) do
    with {:ok, questions} <- load(repo_path) do
      answers =
        case PendingAnswers.load(repo_path) do
          nil -> []
          payload -> payload.answers
        end

      {:ok,
       Enum.reject(questions, fn question ->
         Enum.any?(answers, &answers?(&1, question))
       end)}
    end
  end

  @doc "The obligation file belongs to the worktree, not the branch or release."
  @spec path_for(String.t()) :: String.t()
  def path_for(repo_path), do: Path.join(Git.meerkat_dir(repo_path), "pending-questions.json")

  # An error is a sentence naming the file, for the agent to read.
  defp load(repo_path) do
    path = path_for(repo_path)

    with {:ok, content} <- File.read(path),
         {:ok, %{"version" => 1, "questions" => questions}} <- Jason.decode(content),
         true <- is_list(questions) and Enum.all?(questions, &valid_question?/1) do
      {:ok,
       Enum.map(questions, fn q ->
         %{location: q["location"], question: q["question"]}
       end)}
    else
      {:error, :enoent} -> {:ok, []}
      {:error, %Jason.DecodeError{}} -> {:error, "#{path} is not valid JSON"}
      {:error, posix} -> {:error, "#{path}: #{:file.format_error(posix)}"}
      _ -> {:error, "#{path} is not a version-1 owed-questions file"}
    end
  end

  defp valid_question?(%{"location" => location, "question" => question}),
    do: is_binary(location) and is_binary(question)

  defp valid_question?(_), do: false

  defp answers?(answer, question) do
    answer.location == question.location and answer.question == question.question and
      is_binary(answer.answer) and String.trim(answer.answer) != ""
  end
end
