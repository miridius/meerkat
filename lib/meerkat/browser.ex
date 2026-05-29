defmodule Meerkat.Browser do
  @moduledoc """
  Spawn the OS-native "open this URL" command. Single source of truth
  for `open` (macOS) / `xdg-open` (Linux) / `cmd /c start` (Windows)
  dispatch — used by `Meerkat.CLI` to open the review tab once on
  startup.

  Best-effort: callers fall back to printing the URL on stderr when
  `open/1` returns an error.
  """

  @type result :: :ok | {:error, String.t()}

  @doc """
  Run the OS "open" command against `url`. Returns `:ok` if the
  command exited zero; `{:error, reason}` otherwise (executable
  missing, non-zero exit, etc).
  """
  @spec open(String.t()) :: result
  def open(url) when is_binary(url) do
    {cmd, args} = open_argv(url)

    try do
      case System.cmd(cmd, args, stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, code} ->
          {:error, "#{cmd} exited #{code}: #{String.trim(output)}"}
      end
    rescue
      e in ErlangError -> {:error, Exception.message(e)}
    end
  end

  defp open_argv(url), do: open_argv_for(:os.type(), url)

  @doc false
  # Test seam for the OS-dispatch table.
  def open_argv_for({:unix, :darwin}, url), do: {"open", [url]}
  def open_argv_for({:unix, _}, url), do: {"xdg-open", [url]}
  def open_argv_for({:win32, _}, url), do: {"cmd", ["/c", "start", "", url]}
end
