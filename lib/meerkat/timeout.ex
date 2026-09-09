defmodule Meerkat.Timeout do
  @moduledoc """
  The cap on how long one review may block the commit that asked for it.

  The clock starts when a review is first requested and is anchored on
  disk at `<gitdir>/meerkat-precommit/deadlines/<review_id>`, so a BEAM
  respawned by the shepherd resumes the remaining time rather than
  granting another full window.

  An agent's `git commit` blocks on this, and the agent sits idle until
  someone answers. Its prompt cache lives an hour, so a review answered
  after that charges the whole context as a cache write plus input
  rather than a cache read.
  """

  alias Meerkat.{AtomicFile, Feedback, Git, Persistence, ReviewServer, ReviewState}

  @default_limit_ms 30 * 60 * 1000
  @check_interval_ms 15_000

  @doc """
  Returns how long a review may run, in milliseconds. `MEERKAT_REVIEW_TIMEOUT`
  overrides the default, in whole seconds.
  """
  @spec limit_ms() :: pos_integer()
  def limit_ms do
    with raw when is_binary(raw) <- System.get_env("MEERKAT_REVIEW_TIMEOUT"),
         {seconds, ""} <- Integer.parse(String.trim(raw)),
         true <- seconds > 0 do
      seconds * 1000
    else
      _ -> @default_limit_ms
    end
  end

  @spec check_interval_ms() :: pos_integer()
  def check_interval_ms do
    Application.get_env(:meerkat, :deadline_check_ms, @check_interval_ms)
  end

  @doc """
  Returns the epoch millisecond at which `review_id` runs out. Writes the
  anchor on the first call for that id and reads it back on every later
  one, so the answer is stable across a respawn.
  """
  @spec deadline_ms(String.t(), String.t()) :: integer()
  def deadline_ms(repo_path, review_id) do
    started_at_ms(repo_path, review_id) + limit_ms()
  end

  @spec expired?(integer()) :: boolean()
  def expired?(deadline_ms), do: System.system_time(:millisecond) >= deadline_ms

  @doc """
  Deletes `review_id`'s anchor, so the next review under that id starts a
  fresh clock. Call it once the review has reached a decision.
  """
  @spec clear(String.t(), String.t()) :: :ok
  def clear(repo_path, review_id) do
    _ = File.rm(path_for(repo_path, review_id))
    :ok
  end

  @doc """
  Returns the decision for a review that ran out of time, carrying whatever
  comments were saved before it did. Never raises: it is called from the
  `Meerkat.Decision` process, and an exception there would reach the CLI as
  a crash and abort the commit.
  """
  @spec decision(String.t(), String.t()) :: {:timeout, String.t()}
  def decision(repo_path, review_id) do
    {:timeout, pending_feedback(repo_path, review_id)}
  end

  defp pending_feedback(repo_path, review_id) do
    case review_state(repo_path, review_id) do
      %ReviewState{} = state -> Feedback.format(state, repo_path, :timeout)
      nil -> ""
    end
  end

  # `ReviewServer` only exists once a browser has mounted the review, and
  # comments typed into a tab that was then closed live on in the snapshot.
  # Read that directly rather than losing them to the timeout.
  defp review_state(repo_path, review_id) do
    ReviewServer.get_state(review_id)
  catch
    _, _ -> saved_state(repo_path, review_id)
  end

  defp saved_state(repo_path, review_id) do
    case Application.get_env(:meerkat, :review_state) do
      %ReviewState{} = base -> Persistence.load(repo_path, review_id, base)
      _ -> nil
    end
  catch
    _, _ -> nil
  end

  defp started_at_ms(repo_path, review_id) do
    path = path_for(repo_path, review_id)

    with {:ok, raw} <- File.read(path),
         {ms, _} <- Integer.parse(String.trim(raw)) do
      ms
    else
      _ ->
        now = System.system_time(:millisecond)
        _ = AtomicFile.write(path, Integer.to_string(now))
        now
    end
  end

  defp path_for(repo_path, review_id) do
    Path.join([Git.meerkat_dir(repo_path), "deadlines", review_id])
  end
end
