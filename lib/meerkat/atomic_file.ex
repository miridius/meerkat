defmodule Meerkat.AtomicFile do
  @moduledoc """
  Atomic file write via `<path>.tmp.<unique>` + `File.rename/2`.
  `rename/2` is atomic within a filesystem so readers see either the
  old contents or the new ones, never a half-written file. Used by
  every meerkat write that persists state — comments / approvals /
  review log.

  Best-effort tmp cleanup on failure: if rename succeeds the tmp file
  is gone by definition; if any earlier step fails, we attempt to
  remove the tmp and log on rm-failure so a leaked tmp shows up
  before it accumulates.
  """

  @doc """
  Write `body` to `path`, making parent dirs as needed. Returns `:ok`
  or `{:error, reason}` for the first failing step.
  """
  @spec write(String.t(), iodata()) :: :ok | {:error, term()}
  def write(path, body) do
    tmp = "#{path}.tmp.#{:erlang.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = err ->
        cleanup_tmp(tmp)
        err
    end
  end

  defp cleanup_tmp(tmp) do
    case File.rm(tmp) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> log_rm_failure(tmp, reason)
    end
  end

  defp log_rm_failure(path, reason) do
    IO.puts(:stderr, "meerkat: tmp cleanup at #{path} failed: #{inspect(reason)}")
  end
end
