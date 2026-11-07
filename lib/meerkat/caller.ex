defmodule Meerkat.Caller do
  @moduledoc """
  Whether the invocation waiting on this review, the caller the launcher
  records in its run dir's `caller` file, is gone. `Meerkat.Decision` asks
  until a caller attaches, so a review whose invocation died before it
  attached can still end.

  Mirrors the launcher's own check in `bin/meerkat-attach`: a caller is
  gone only once `ps` shows its pid is not a running meerkat, as a reused
  pid would run something else. When the file cannot be read, or `ps`
  cannot see processes at all (a sandbox denies it), it cannot tell, and
  says the caller is not gone: taking it for gone would end a review
  someone still waits on.
  """

  @doc """
  Whether `serve_dir`'s recorded caller is known to have exited.
  `command` returns a pid's command line, or "" when `ps` shows none.
  """
  @spec gone?(String.t(), (String.t() | integer() -> String.t())) :: boolean()
  def gone?(serve_dir, command \\ &command/1) do
    with {:ok, raw} <- File.read(Path.join(serve_dir, "caller")),
         {pid, ""} <- Integer.parse(String.trim(raw)),
         # ps lists this BEAM itself whenever it can see processes.
         true <- command.(System.pid()) != "" do
      not String.contains?(command.(pid), ["meerkat", "Meerkat"])
    else
      _ -> false
    end
  end

  # A missing `ps` sees no process, like a denied one.
  @doc false
  def command(pid, ps \\ "ps") do
    {out, _status} = System.cmd(ps, ["-p", to_string(pid), "-o", "command="])
    String.trim(out)
  rescue
    ErlangError -> ""
  end
end
