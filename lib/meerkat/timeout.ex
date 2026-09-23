defmodule Meerkat.Timeout do
  @moduledoc """
  The cap on how long one review may block the commit that asked for it.

  The clock starts when a review is first requested and is anchored on
  disk under `<gitdir>/meerkat-precommit/deadlines/<run>/<review_id>`,
  where `<run>` is the launcher's `MEERKAT_RUN_ID`. A BEAM respawned by
  the shepherd is the same run and resumes the remaining time; a later
  `git commit` is a new one and gets a full window.

  An agent's `git commit` blocks on this, and the agent sits idle until
  someone answers. Its prompt cache lives an hour, so a review answered
  after that charges the whole context as a cache write plus input
  rather than a cache read.
  """

  alias Meerkat.{AtomicFile, Feedback, Git, Persistence, ReviewServer, ReviewState}

  @default_limit_ms 30 * 60 * 1000
  @check_interval_ms 15_000
  @unkeyed_run "unkeyed"

  @doc """
  Returns how long a review may run, in milliseconds. `MEERKAT_REVIEW_TIMEOUT`
  overrides the default, in whole seconds; `0` disables the deadline
  entirely, leaving the review open until a human answers or kills it.
  """
  @spec limit_ms() :: pos_integer() | :infinity
  def limit_ms do
    with raw when is_binary(raw) <- System.get_env("MEERKAT_REVIEW_TIMEOUT"),
         {seconds, ""} <- Integer.parse(String.trim(raw)),
         true <- seconds >= 0 do
      if seconds == 0, do: :infinity, else: seconds * 1000
    else
      _ -> @default_limit_ms
    end
  end

  @doc """
  True when `MEERKAT_REVIEW_TIMEOUT=0` has disabled the deadline entirely.
  """
  @spec disabled?() :: boolean()
  def disabled?, do: limit_ms() == :infinity

  @spec check_interval_ms() :: pos_integer()
  def check_interval_ms do
    Application.get_env(:meerkat, :deadline_check_ms, @check_interval_ms)
  end

  @doc """
  Returns the epoch millisecond at which `review_id` runs out — nil when
  the deadline is disabled. Stable across every call within one launcher
  run, and fresh in the next one.
  """
  @spec deadline_ms(String.t(), String.t()) :: integer() | nil
  def deadline_ms(repo_path, review_id) do
    if disabled?(), do: nil, else: started_at_ms(repo_path, review_id) + limit_ms()
  end

  @spec expired?(integer()) :: boolean()
  def expired?(deadline_ms), do: System.system_time(:millisecond) >= deadline_ms

  @doc """
  Deletes `review_id`'s anchor, and this run's deadline directory once it
  holds nothing else.
  """
  @spec clear(String.t(), String.t()) :: :ok
  def clear(repo_path, review_id) do
    _ = File.rm(path_for(repo_path, review_id))
    _ = File.rmdir(run_dir(repo_path))
    :ok
  end

  @doc """
  Deletes the deadline directory of every run but this one, once it is
  older than `limit_ms/0`. Never prunes when the deadline is disabled:
  there is no age past which a still-live run's anchor is stale.
  """
  @spec prune_stale(String.t()) :: :ok
  def prune_stale(repo_path) do
    if disabled?() do
      :ok
    else
      do_prune_stale(repo_path)
    end
  end

  defp do_prune_stale(repo_path) do
    parent = Path.dirname(run_dir(repo_path))
    keep = run_id()
    cutoff_s = System.system_time(:second) - div(limit_ms(), 1000)

    case File.ls(parent) do
      {:ok, entries} ->
        for entry <- entries, entry != keep, older_than?(Path.join(parent, entry), cutoff_s) do
          _ = File.rm_rf(Path.join(parent, entry))
        end

      _ ->
        :ok
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp older_than?(path, cutoff_s) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime < cutoff_s
      _ -> false
    end
  end

  @doc """
  Returns the decision for a review that ran out of time, carrying whatever
  comments were saved before it did. Never raises: a snapshot it cannot
  read yields no comments instead.
  """
  @spec decision(String.t(), String.t()) :: {:timeout, String.t()}
  def decision(repo_path, review_id) do
    {:timeout, pending_feedback(repo_path, review_id)}
  end

  defp pending_feedback(repo_path, review_id) do
    case review_state(repo_path, review_id) do
      %ReviewState{} = state -> Feedback.format(state, :timeout)
      nil -> ""
    end
  catch
    kind, reason ->
      IO.puts(
        :stderr,
        "meerkat: warning — couldn't read the comments saved for #{review_id}: " <>
          "#{inspect(kind)} #{inspect(reason)}. Auto-approving without them."
      )

      ""
  end

  # `ReviewServer` is started by the first LiveView mount, so a review
  # nobody has opened, or one whose BEAM respawned with nobody
  # reconnected, has none. Its comments are still on disk.
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
    Path.join([run_dir(repo_path), review_id])
  end

  defp run_dir(repo_path) do
    Path.join([Git.meerkat_dir(repo_path), "deadlines", run_id()])
  end

  defp run_id do
    with raw when is_binary(raw) <- System.get_env("MEERKAT_RUN_ID"),
         trimmed when trimmed != "" <- String.trim(raw) do
      # `basename` so a run id carrying slashes cannot put the anchor
      # outside the deadlines directory.
      Path.basename(trimmed)
    else
      _ -> @unkeyed_run
    end
  end
end
