defmodule Meerkat.Quarantine do
  @moduledoc """
  Side-step a malformed-but-named file by renaming it to
  `<path>.corrupt.<unix-ts>` and logging the move to stderr. Used by
  `Meerkat.Persistence`, `Meerkat.ApprovalCache`, and
  `Meerkat.PendingAnswers` whenever a JSON load fails — the next
  invocation gets a clean slate while the broken file stays on disk
  for forensics.
  """

  @doc """
  Rename `path` to `<path>.corrupt.<unix-ts>` and write a stderr
  warning. `label` is the noun for the user-facing message (e.g.
  "approval cache", "in-progress snapshot"). `success_suffix` is
  appended on a successful rename — typically " Starting from an
  empty <thing>." so the user knows recovery happened.
  """
  @spec move(String.t(), String.t(), String.t(), String.t()) :: :ok
  def move(path, reason, label, success_suffix \\ "") do
    ts = System.system_time(:second)
    corrupt = "#{path}.corrupt.#{ts}"

    case File.rename(path, corrupt) do
      :ok ->
        IO.puts(
          :stderr,
          "meerkat: warning — #{label} at #{path} unusable (#{reason}); " <>
            "moved to #{corrupt}.#{success_suffix}"
        )

      {:error, _} ->
        IO.puts(
          :stderr,
          "meerkat: warning — #{label} at #{path} unusable (#{reason})"
        )
    end

    :ok
  end
end
