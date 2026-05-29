defmodule Meerkat.PlantUML do
  @moduledoc """
  Render `.puml` diagram source to SVG via the locally-installed
  `plantuml` CLI. SANDBOX security profile blocks `!include` of
  arbitrary files / URLs; 30s timeout; source piped on stdin, SVG on
  stdout. plantuml's stderr is captured so syntax errors propagate
  back to the LV (the user sees the actual diagnosis, not just "exit
  code 1").

  `available?/0` probes `plantuml -version` once per call — the LV
  caches the result via socket assigns (per-LV-session).
  """

  @timeout_ms 30_000

  @doc "True iff `plantuml -version` succeeds. Cached by `MeerkatWeb.ReviewLive` on mount."
  @spec available?() :: boolean()
  def available? do
    case System.cmd("plantuml", ["-version"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Render PlantUML source to SVG bytes. Returns `{:ok, svg}` on success
  or `{:error, reason}` on any failure (binary missing, timeout, parse
  error, IO error). plantuml stderr is included verbatim in the
  reason on a non-zero exit so the user can read the diagnostic.
  """
  @spec render(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def render(source) when is_binary(source) do
    case render_via_port(source) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        IO.puts(:stderr, "meerkat: plantuml render failed — #{reason}")
        err
    end
  end

  # Spawn plantuml directly via Port so stdin can be fed the source
  # without shell-string interpolation. `-pipe` reads source from
  # stdin and writes SVG to stdout. `2>&1` captured via Port's
  # `:stderr_to_stdout`.
  defp render_via_port(source) do
    plantuml = System.find_executable("plantuml")

    if is_nil(plantuml) do
      {:error, "plantuml binary not found on PATH"}
    else
      port =
        Port.open(
          {:spawn_executable, plantuml},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :use_stdio,
            args: ["-tsvg", "-pipe", "-nbthread", "1"],
            env: [{~c"PLANTUML_SECURITY_PROFILE", ~c"SANDBOX"}]
          ]
        )

      send(port, {self(), {:command, source}})
      send(port, {self(), :close})

      collect(port, [], @timeout_ms)
    end
  end

  defp collect(port, acc, remaining_ms) do
    started = System.monotonic_time(:millisecond)

    receive do
      {^port, {:data, data}} ->
        elapsed = System.monotonic_time(:millisecond) - started
        collect(port, [acc, data], max(0, remaining_ms - elapsed))

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, code}} ->
        {:error,
         "plantuml exited #{code}.\nplantuml output:\n#{String.trim(IO.iodata_to_binary(acc))}"}
    after
      remaining_ms ->
        partial = String.trim(IO.iodata_to_binary(acc))
        kill_port(port)

        msg = "plantuml did not finish within #{@timeout_ms}ms; the process was killed."

        {:error,
         if(partial == "",
           do: msg,
           else: msg <> "\nplantuml output before the timeout:\n" <> partial
         )}
    end
  end

  # Port.close drops the pipe but doesn't reap a CPU-bound child.
  # SIGKILL the OS pid first so a stuck plantuml doesn't outlive the
  # request and pile up on the host.
  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    _ = Port.close(port)
    :ok
  end
end
