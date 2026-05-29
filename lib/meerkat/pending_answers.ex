defmodule Meerkat.PendingAnswers do
  @moduledoc """
  Loads / clears the `pending-answers.json` file Claude writes after a
  prior review's question-type comments. The file is per-worktree at
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
  Schema version of the on-disk pending-answers file. Included in the
  directive Claude reads so older binaries refuse to consume answers
  written for a newer shape.
  """
  @spec version() :: pos_integer()
  def version, do: @version

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

  defp decode_answer(%{"location" => loc, "question" => q, "answer" => a}) do
    [%{location: loc, question: q, answer: a}]
  end

  defp decode_answer(_), do: []

  defp quarantine(path, reason) do
    Meerkat.Quarantine.move(path, reason, "pending-answers")
  end
end
