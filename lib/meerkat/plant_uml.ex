defmodule Meerkat.PlantUML do
  @moduledoc """
  Render `.puml` diagram source to SVG via the locally-installed
  `plantuml` CLI. SANDBOX security profile blocks `!include` of
  arbitrary files / URLs; 30s timeout; source redirected onto stdin
  from a tmp file, SVG written from stdout to another tmp file and
  read back. plantuml's stderr is captured so syntax errors propagate
  back to the LV (the user sees the actual diagnosis, not just "exit
  code 1").

  `available?/0` probes `plantuml -version` once per BEAM and caches
  the answer: the probe starts a JVM, about half a second, and every
  render of a review with a PlantUML file asks.
  """

  @timeout_ms 30_000
  @available_key {__MODULE__, :available?}

  @doc "True iff `plantuml -version` succeeded the first time this BEAM asked."
  @spec available?() :: boolean()
  def available? do
    case :persistent_term.get(@available_key, nil) do
      nil ->
        available = probe()
        :persistent_term.put(@available_key, available)
        available

      available ->
        available
    end
  end

  defp probe do
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

  # `-pipe` reads source from stdin and writes SVG to stdout. plantuml
  # only exits at stdin EOF, and a Port can't close the child's stdin
  # without closing the whole port (dropping the output and exit
  # status), so `sh` redirects a tmp file of the source onto stdin.
  # stdout goes to a second tmp file and stderr to the port: on a
  # syntax error plantuml writes an error-image SVG to stdout and the
  # diagnosis to stderr, and only the diagnosis belongs in the reason.
  # The paths are positional args, never interpolated into the script,
  # and `exec` keeps the OS pid plantuml's for kill_port/1.
  defp render_via_port(source) do
    plantuml = System.find_executable("plantuml")

    if is_nil(plantuml) do
      {:error, "plantuml binary not found on PATH"}
    else
      # System.unique_integer/1 is unique only within this BEAM, and
      # every meerkat process shares the tmp dir, so the OS pid keeps
      # concurrent meerkats off each other's files.
      base =
        Path.join(
          System.tmp_dir!(),
          "meerkat-puml-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      src_path = base <> ".puml"
      svg_path = base <> ".svg"

      try do
        with :ok <- file_result(File.write(src_path, source), "writing", src_path),
             {:ok, _diagnostics} <-
               collect(open_port(plantuml, src_path, svg_path), [], @timeout_ms) do
          file_result(File.read(svg_path), "reading", svg_path)
        end
      after
        File.rm(src_path)
        File.rm(svg_path)
      end
    end
  end

  defp open_port(plantuml, src_path, svg_path) do
    Port.open(
      {:spawn_executable, "/bin/sh"},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        args: [
          "-c",
          ~s(exec "$0" -tsvg -pipe -nbthread 1 < "$1" 2>&1 > "$2"),
          plantuml,
          src_path,
          svg_path
        ],
        env: [{~c"PLANTUML_SECURITY_PROFILE", ~c"SANDBOX"}]
      ]
    )
  end

  defp file_result({:error, posix}, verb, path),
    do: {:error, "#{verb} #{path} failed: #{:file.format_error(posix)}"}

  defp file_result(result, _verb, _path), do: result

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

    # The killed child can close the port first, and Port.close raises
    # ArgumentError on a closed port.
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # Test seam: plantuml_test.exs times a render out against a stuck child
  # without waiting the 30s budget.
  @doc false
  def collect_for_test(port, acc, remaining_ms), do: collect(port, acc, remaining_ms)
end
