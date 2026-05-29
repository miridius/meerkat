defmodule Meerkat.ApprovalCache do
  @moduledoc """
  Per-branch, per-file approval cache, shared across worktrees of the
  same repo via `<gitdir>/meerkat-precommit/approved.json`.

  Approvals are content-addressed via git blob OIDs — a file's effective
  OID changes iff its content changes, so an approval matches only when
  the file is byte-identical to what the reviewer saw. Each file holds
  a *set* of approved OIDs so content flip-flops during iteration don't
  lose approvals (approve A → edit to B → revert to A still matches A).

  Mutations go through `modify/2`, which read-modify-writes via atomic
  rename guarded by a cross-process advisory lock (`<path>.lock.d`,
  POSIX-atomic `mkdir`, 25 ms backoff up to 10 s, force-take if a
  killed previous writer leaked the lockdir). Approval state is pure
  UX sugar, never load-bearing — a missed write costs at most one
  re-tick of an Approved checkbox.
  """

  @cache_version 2

  @type branch :: String.t()
  @type file_name :: String.t()
  @type oid :: String.t()
  @type t :: %{optional(branch) => %{optional(file_name) => [oid]}}

  @doc """
  Resolve `<git-common-dir>/meerkat-precommit/approved.json` — shared
  across worktrees of the same repo.
  """
  @spec path_for(String.t()) :: String.t() | nil
  def path_for(repo_path) do
    case Meerkat.Git.git_common_dir(repo_path) do
      {:ok, common} -> Path.join([common, "meerkat-precommit", "approved.json"])
      {:error, _} -> nil
    end
  end

  @doc """
  Resolve + load in one call. Returns `%{}` when the git-common-dir
  lookup fails (no shared cache to read), letting callers always have
  a usable map.
  """
  @spec load_for(String.t()) :: t
  def load_for(repo_path) do
    case path_for(repo_path) do
      nil -> %{}
      path -> load(path)
    end
  end

  @doc """
  Read the cache file. Missing → empty. Malformed / wrong-version
  files are logged to stderr and quarantined to `.corrupt.<ts>` so
  the next save doesn't overwrite a file the user might still want.
  """
  @spec load(String.t()) :: t
  def load(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"version" => @cache_version, "branches" => branches}} when is_map(branches) ->
            branches

          {:ok, %{"version" => other}} ->
            quarantine(
              path,
              "schema version mismatch (got #{inspect(other)}, want #{@cache_version})"
            )

            %{}

          {:ok, _} ->
            quarantine(path, "missing version/branches keys")
            %{}

          {:error, %Jason.DecodeError{} = err} ->
            quarantine(path, "JSON parse failed: #{Exception.message(err)}")
            %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        IO.puts(
          :stderr,
          "meerkat: warning — couldn't read approval cache at #{path}: #{inspect(reason)}"
        )

        %{}
    end
  end

  defp quarantine(path, reason) do
    Meerkat.Quarantine.move(
      path,
      reason,
      "approval cache",
      " Starting from an empty cache."
    )
  end

  @doc """
  Write `cache` atomically to `path`. Returns `:ok` or `{:error, ...}`.
  Best-effort — callers must NOT block on the result.
  """
  @spec save(t, String.t()) :: :ok | {:error, term()}
  def save(cache, path) do
    body =
      Jason.encode!(%{version: @cache_version, branches: cache}, pretty: true)

    case Meerkat.AtomicFile.write(path, body) do
      :ok ->
        :ok

      {:error, reason} = err ->
        IO.puts(
          :stderr,
          "meerkat: warning — couldn't save approval cache to #{path}: #{inspect(reason)}"
        )

        err
    end
  end

  @doc """
  True if `(branch, file_name, oid)` is in the cache.
  """
  @spec approved?(t, branch, file_name, oid) :: boolean
  def approved?(cache, branch, file_name, oid) do
    cache
    |> Map.get(branch, %{})
    |> Map.get(file_name, [])
    |> Enum.any?(&(&1 == oid))
  end

  @doc """
  Add `(branch, file_name, oid)` to the cache. Idempotent.
  """
  @spec approve(t, branch, file_name, oid) :: t
  def approve(cache, branch, file_name, oid) do
    Map.update(cache, branch, %{file_name => [oid]}, fn files ->
      Map.update(files, file_name, [oid], fn oids ->
        if oid in oids, do: oids, else: [oid | oids]
      end)
    end)
  end

  @doc """
  Remove every approval for `(branch, file_name)`. Used when the user
  un-ticks the Approved checkbox.
  """
  @spec unapprove(t, branch, file_name) :: t
  def unapprove(cache, branch, file_name) do
    case Map.get(cache, branch) do
      nil ->
        cache

      files ->
        files = Map.delete(files, file_name)

        if files == %{},
          do: Map.delete(cache, branch),
          else: Map.put(cache, branch, files)
    end
  end

  @doc """
  Drop sub-trees for branches not in `known`. Called at hook-run time
  so deleted branches stop taking up space.
  """
  @spec prune(t, MapSet.t(branch)) :: t
  def prune(cache, known) do
    cache
    |> Enum.filter(fn {branch, _} -> MapSet.member?(known, branch) end)
    |> Map.new()
  end

  @doc """
  Read-modify-write `path` via `fun`. Atomic on disk via tmp-rename;
  cross-process mutual exclusion via a `<path>.lock.d` lockdir
  (POSIX-atomic `mkdir`, 10 s wait then force-take).
  """
  @spec modify(String.t(), (t -> t)) :: {:ok, t} | {:error, term()}
  def modify(path, fun) when is_function(fun, 1) do
    # Cross-process advisory lock via atomic mkdir of `<path>.lock.d`.
    # POSIX mkdir is atomic — the kernel either creates the directory
    # and we own it, or returns EEXIST and another worktree's commit
    # owns it. Spin with 25ms backoff up to 10s, then take the lock
    # by force (stale lockdir from a killed process is the only way
    # the wait exceeds reasonable bounds — release happens in the
    # `after` block, and a SIGKILL during the critical section is
    # the only way to leak it). On lock-acquisition failure we
    # propagate `{:error, _}` so callers can surface the problem
    # rather than risk silently clobbering another worktree's write.
    lock_dir = "#{path}.lock.d"

    with :ok <- mkdir_p_or_log(Path.dirname(lock_dir)),
         {:ok, :acquired} <- acquire_lockdir(lock_dir, 10_000) do
      try do
        new_cache = path |> load() |> fun.()

        case save(new_cache, path) do
          :ok -> {:ok, new_cache}
          err -> err
        end
      after
        case File.rmdir(lock_dir) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> log_rmdir_failure(lock_dir, reason)
        end
      end
    end
  end

  defp mkdir_p_or_log(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} = err ->
        IO.puts(
          :stderr,
          "meerkat: warning — couldn't create approval-cache directory at #{dir}: " <>
            "#{inspect(reason)}. Approval ticks won't persist this session."
        )

        err
    end
  end

  defp log_rmdir_failure(lock_dir, reason) do
    IO.puts(
      :stderr,
      "meerkat: warning — couldn't release approval-cache lock at #{lock_dir}: " <>
        "#{inspect(reason)}. Next concurrent writer will force-take after 10s."
    )
  end

  # Returns `{:ok, :acquired}` if we own the lockdir, `{:error, _}`
  # otherwise. Callers that get the error MUST NOT proceed with the
  # mutation — without the lock, concurrent worktrees can clobber
  # each other's writes.
  defp acquire_lockdir(lock_dir, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    acquire_loop(lock_dir, deadline)
  end

  defp acquire_loop(lock_dir, deadline) do
    case File.mkdir(lock_dir) do
      :ok ->
        {:ok, :acquired}

      {:error, :eexist} ->
        if System.monotonic_time(:millisecond) > deadline do
          IO.puts(
            :stderr,
            "meerkat: warning — approval-cache lock at #{lock_dir} held for >10s. " <>
              "Likely stale (killed meerkat). Forcing take."
          )

          _ = File.rmdir(lock_dir)
          # One more try; if it still EEXISTs, give up acquiring.
          case File.mkdir(lock_dir) do
            :ok -> {:ok, :acquired}
            {:error, reason} -> {:error, {:lock_failed, reason}}
          end
        else
          Process.sleep(25)
          acquire_loop(lock_dir, deadline)
        end

      {:error, reason} ->
        IO.puts(
          :stderr,
          "meerkat: warning — couldn't acquire approval-cache lock at #{lock_dir}: " <>
            "#{inspect(reason)}. Skipping cache write to avoid clobbering concurrent worktrees."
        )

        {:error, {:lock_failed, reason}}
    end
  end
end
