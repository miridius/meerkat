defmodule Meerkat.PendingAnswers do
  @moduledoc """
  Stores, loads and clears the `pending-answers.json` file holding the
  agent's answers to a prior review's question-type comments, as
  handed over via `meerkat --answers`. The file is per-worktree at
  `<per-worktree-gitdir>/meerkat-precommit/pending-answers.json`.
  Schema version 1; returns `nil` for missing / empty payloads.
  Malformed / wrong-version files are logged to stderr and the bad file
  renamed to `.corrupt.<unix-ts>` so a future hand-edit doesn't get
  silently overwritten.

  ## Schema version

  Files written by a different binary version (whose `version` field
  doesn't match `@version`) are also quarantined — the writer's intent
  isn't recoverable here.

  Per-worktree (not git-common-dir) because pending answers belong to
  one review session in one worktree.
  """

  @version 1

  @type answer :: %{location: String.t(), question: String.t(), answer: String.t()}
  @type payload :: %{version: pos_integer(), created_at: String.t(), answers: [answer]}

  @doc """
  Store `input`, the agent's answers as JSON of the shape
  `{"answers": [{"location", "question", "answer"}, ...]}`, as this
  repo's pending-answers file, replacing any earlier one. Returns
  `{:ok, count}` with the number of answers stored, or
  `{:error, message}` having written nothing.
  """
  @spec save(String.t(), binary()) :: {:ok, pos_integer()} | {:error, String.t()}
  def save(repo_path, input) do
    with :ok <- require_git_repo(repo_path),
         {:ok, answers} <- parse_input(input),
         :ok <- write(repo_path, answers) do
      {:ok, length(answers)}
    end
  end

  @doc "Load pending answers for `repo_path`. Returns `nil` if absent / malformed / empty."
  @spec load(String.t()) :: payload | nil
  def load(repo_path) do
    path = path_for(repo_path)

    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      case decoded do
        %{"version" => @version, "answers" => answers, "createdAt" => created_at}
        when is_list(answers) and answers != [] ->
          %{
            version: @version,
            created_at: created_at,
            answers: Enum.flat_map(answers, &decode_answer/1)
          }

        %{"version" => @version, "answers" => []} ->
          nil

        _ ->
          quarantine(path, "schema mismatch (expected version #{@version})")
          nil
      end
    else
      {:error, :enoent} ->
        nil

      {:error, %Jason.DecodeError{} = err} ->
        quarantine(path, "JSON parse failed: #{Exception.message(err)}")
        nil

      {:error, reason} ->
        IO.puts(
          :stderr,
          "meerkat: warning — couldn't read pending-answers at #{path}: #{inspect(reason)}"
        )

        nil
    end
  end

  @doc "Delete the pending-answers file after a decision. Missing file is a no-op."
  @spec clear(String.t()) :: :ok
  def clear(repo_path) do
    path = path_for(repo_path)

    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        IO.puts(
          :stderr,
          "meerkat: warning — couldn't delete pending-answers at #{path}: #{inspect(reason)}. " <>
            "Banner may reappear on the next review."
        )

        :ok
    end
  end

  @doc """
  Path the pending-answers file lives at for this repo's worktree.

  Resolved via `git rev-parse --git-dir` so secondary worktrees get
  `.git/worktrees/<name>/meerkat-precommit/pending-answers.json`.
  """
  @spec path_for(String.t()) :: String.t()
  def path_for(repo_path) do
    Path.join(Meerkat.Git.meerkat_dir(repo_path), "pending-answers.json")
  end

  # `Meerkat.Git.meerkat_dir/1` falls back to `<repo_path>/.git` when
  # this fails, and a write there would plant a `.git/` in a directory
  # that isn't a repo.
  defp require_git_repo(repo_path) do
    case Meerkat.Git.git_dir(repo_path) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "not a git repository: #{reason}"}
    end
  end

  defp parse_input(input) do
    case Jason.decode(input) do
      {:ok, %{"answers" => answers}} when is_list(answers) and answers != [] ->
        validate_answers(answers)

      {:ok, %{"answers" => []}} ->
        {:error, ~s("answers" must not be empty)}

      {:ok, %{"answers" => _}} ->
        {:error, ~s("answers" must be a list)}

      {:ok, %{}} ->
        {:error, ~s(missing "answers" list)}

      {:ok, _} ->
        {:error, ~s(expected a JSON object with an "answers" list)}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, "invalid JSON: #{Exception.message(err)}"}
    end
  end

  defp validate_answers(answers) do
    answers
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{"location" => loc, "question" => q, "answer" => a}, _}, {:ok, acc}
      when is_binary(loc) and is_binary(q) and is_binary(a) ->
        {:cont, {:ok, [%{"location" => loc, "question" => q, "answer" => a} | acc]}}

      {_, idx}, _ ->
        {:halt,
         {:error, ~s(answers[#{idx}] must have string "location", "question" and "answer")}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp write(repo_path, answers) do
    created_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    payload = %{"version" => @version, "createdAt" => created_at, "answers" => answers}
    path = path_for(repo_path)

    case Meerkat.AtomicFile.write(path, Jason.encode!(payload)) do
      :ok -> :ok
      {:error, reason} -> {:error, "couldn't write #{path}: #{inspect(reason)}"}
    end
  end

  defp decode_answer(%{"location" => loc, "question" => q, "answer" => a}) do
    [%{location: loc, question: q, answer: a}]
  end

  defp decode_answer(_), do: []

  defp quarantine(path, reason) do
    Meerkat.Quarantine.move(path, reason, "pending-answers")
  end
end
