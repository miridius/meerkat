defmodule Meerkat.ShepherdTest do
  # Runs the real bin/meerkat-shepherd, through its caller half in
  # bin/meerkat-attach, against a fake release BEAM whose per-iteration
  # exit codes are scripted. This pins the exit-code contract the prod
  # launcher rests on.
  use ExUnit.Case, async: true

  @shepherd Path.join(File.cwd!(), "bin/meerkat-shepherd")
  @timeout_ms 10_000

  test "restarts on exit 75, then propagates a clean decision" do
    assert run_shepherd([75, 75, 0]) == %{code: 0, iterations: 3}
  end

  test "retries a crash (exit 2) once, then propagates a clean decision" do
    assert run_shepherd([2, 0]) == %{code: 0, iterations: 2}
  end

  test "aborts (propagates 2) on a second consecutive crash" do
    assert run_shepherd([2, 2]) == %{code: 2, iterations: 2}
  end

  test "propagates a reject (exit 1) straight through" do
    assert run_shepherd([1]) == %{code: 1, iterations: 1}
  end

  test "a 75 restart resets the crash budget" do
    assert run_shepherd([2, 75, 2, 0]) == %{code: 0, iterations: 4}
  end

  test "--answers runs the BEAM once in the foreground with the caller's stdin" do
    input = ~s({"answers":[{"location":"global","question":"q","answer":"a"}]}\n)

    assert run_shepherd([0], args: ["--answers"], input: input) == %{
             code: 0,
             iterations: 1,
             stdin: input
           }
  end

  test "--answers propagates a crash (exit 2) without a retry" do
    assert run_shepherd([2, 0], args: ["--answers"], input: "nope") == %{
             code: 2,
             iterations: 1,
             stdin: "nope"
           }
  end

  # Returns the shepherd's exit code, how many times the fake BEAM ran,
  # and, when `input` is given, what the BEAM read on stdin.
  defp run_shepherd(exit_codes, opts \\ []) do
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
    on_exit(fn -> File.rm_rf!(dir) end)

    rel = Path.join(dir, "rel")
    File.mkdir_p!(Path.join(rel, "bin"))
    File.ln_s!(rel, Path.join(dir, "current"))
    File.write!(Path.join(dir, "seq"), Enum.join(exit_codes, " "))
    File.write!(Path.join(dir, "i"), "0")
    File.write!(Path.join(dir, "stdin"), "")

    File.write!(Path.join([rel, "bin", "meerkat"]), ~S"""
    #!/usr/bin/env bash
    i=$(cat "$I_FILE"); codes=($(cat "$SEQ_FILE"))
    echo $((i + 1)) > "$I_FILE"
    if [[ -n "${STDIN_FILE:-}" ]]; then cat >> "$STDIN_FILE"; fi
    exit "${codes[$i]:-0}"
    """)

    File.chmod!(Path.join([rel, "bin", "meerkat"]), 0o755)

    input = Keyword.get(opts, :input)
    input_file = Path.join(dir, "input")
    if input, do: File.write!(input_file, input)

    env = [
      {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
      {"MEERKAT_PORT", "44444"},
      {"MEERKAT_RUNS_DIR", Path.join(dir, "runs")},
      {"I_FILE", Path.join(dir, "i")},
      {"SEQ_FILE", Path.join(dir, "seq")},
      {"STDIN_FILE", if(input, do: Path.join(dir, "stdin"))},
      {"INPUT_FILE", if(input, do: input_file, else: "/dev/null")},
      # A shepherd run by a caller has this set; the caller itself does not.
      {"MEERKAT_SERVE_DIR", nil}
    ]

    args = Keyword.get(opts, :args, ["--commit-msg", "/tmp/msg", "--no-open"])

    # Piped when there is input, as a caller piping answers in does;
    # /dev/null otherwise.
    script = ~S"""
    if [ "$INPUT_FILE" = /dev/null ]; then exec "$0" "$@" </dev/null; fi
    cat "$INPUT_FILE" | "$0" "$@"
    """

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", script, @shepherd | args],
        env: Enum.map(env, fn {k, v} -> {~c"#{k}", if(v, do: ~c"#{v}", else: false)} end)
      ])

    code = await_exit(port, dir)
    iterations = String.to_integer(String.trim(File.read!(Path.join(dir, "i"))))

    if input,
      do: %{code: code, iterations: iterations, stdin: File.read!(Path.join(dir, "stdin"))},
      else: %{code: code, iterations: iterations}
  end

  defp await_exit(port, dir) do
    receive do
      {^port, {:data, _}} -> await_exit(port, dir)
      {^port, {:exit_status, code}} -> code
    after
      @timeout_ms ->
        # The caller and the detached shepherd it started, which has its
        # own session and would outlive the caller.
        {:os_pid, pid} = Port.info(port, :os_pid)
        detached = Path.wildcard(Path.join([dir, "runs", "*", "pid"]))
        pids = [to_string(pid) | Enum.map(detached, &String.trim(File.read!(&1)))]
        System.cmd("pkill", ["-9", "-P", Enum.join(pids, ",")])
        System.cmd("kill", ["-9" | pids])
        flunk("meerkat-shepherd did not exit within #{@timeout_ms} ms")
    end
  end
end
