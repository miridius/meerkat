defmodule Meerkat.ShepherdTest do
  # Runs the real bin/meerkat-shepherd, through its caller half in
  # bin/meerkat-attach, against a fake release BEAM whose per-iteration
  # exit codes are scripted. This pins the exit-code contract the prod
  # launcher rests on, and the port each launcher, prod and dev, prefers
  # for its BEAMs.
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

  test "without --port, the BEAM prefers the stable port, and a respawn the port the last BEAM bound" do
    assert run_shepherd([75, 2, 0], ports: true) == %{
             code: 0,
             iterations: 3,
             ports: [
               "44444 --commit-msg /tmp/msg --no-open",
               "1 --commit-msg /tmp/msg --no-open",
               "2 --commit-msg /tmp/msg --no-open"
             ]
           }
  end

  test "an explicit --port reaches the BEAM untouched, with no stable port preferred" do
    assert run_shepherd([75, 0], args: ["--commit-msg", "/tmp/msg", "--port", "0"], ports: true) ==
             %{
               code: 0,
               iterations: 2,
               ports: ["none --commit-msg /tmp/msg --port 0", "1 --commit-msg /tmp/msg --port 0"]
             }
  end

  test "an explicit --port=N reaches the BEAM untouched, with no stable port preferred" do
    assert run_shepherd([0], args: ["--commit-msg", "/tmp/msg", "--port=0"], ports: true) == %{
             code: 0,
             iterations: 1,
             ports: ["none --commit-msg /tmp/msg --port=0"]
           }
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

  # A caller that re-reads a stale `port` file reattaches to the exited
  # BEAM's port, which by then another process may hold.
  describe "between a BEAM's exit and its respawn" do
    test "the prod shepherd leaves no port file naming the exited BEAM" do
      seen =
        port_file_between_runs(
          @shepherd,
          "rel/bin/meerkat",
          "",
          [{"readlink", "/usr/bin/readlink"}],
          fn dir ->
            File.ln_s!(Path.join(dir, "rel"), Path.join(dir, "current"))
            [{"MEERKAT_CURRENT_LINK", Path.join(dir, "current")}]
          end
        )

      assert seen == ["beam: 44444", "readlink: none", "beam: 1"]
    end

    test "the dev launcher leaves no port file naming the exited BEAM" do
      seen = Enum.reject(dev_launcher_between_runs(), &String.starts_with?(&1, "beam:"))

      assert seen != []
      assert Enum.filter(seen, &String.ends_with?(&1, "stale")) == []
    end

    test "the dev launcher prefers the stable port, then the port the exited BEAM bound" do
      seen = Enum.filter(dev_launcher_between_runs(), &String.starts_with?(&1, "beam:"))
      assert seen == ["beam: 44444", "beam: 1"]
    end

    test "the dev launcher passes an explicit --port through with no stable port preferred" do
      seen =
        Enum.filter(
          dev_launcher_between_runs(["--commit-msg", "/tmp/msg", "--port", "0"]),
          &String.starts_with?(&1, "beam:")
        )

      assert seen == ["beam: none", "beam: 1"]
    end
  end

  # Returns the shepherd's exit code, how many times the fake BEAM ran,
  # and, when `input` is given, what the BEAM read on stdin. On each
  # iteration i, the fake BEAM writes `<i+1> <pid>` to
  # `$MEERKAT_SERVE_DIR/port`; with `ports: true`, it also returns the
  # preferred port each run saw (`none` if unset) and its args.
  defp run_shepherd(exit_codes, opts \\ []) do
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
    on_exit(fn -> File.rm_rf!(dir) end)

    rel = Path.join(dir, "rel")
    File.mkdir_p!(Path.join(rel, "bin"))
    File.ln_s!(rel, Path.join(dir, "current"))
    File.write!(Path.join(dir, "seq"), Enum.join(exit_codes, " "))
    File.write!(Path.join(dir, "i"), "0")
    File.write!(Path.join(dir, "stdin"), "")
    File.write!(Path.join(dir, "ports"), "")

    File.write!(Path.join([rel, "bin", "meerkat"]), ~S"""
    #!/usr/bin/env bash
    i=$(cat "$I_FILE"); codes=($(cat "$SEQ_FILE"))
    echo $((i + 1)) > "$I_FILE"
    if [[ -n "${STDIN_FILE:-}" ]]; then cat >> "$STDIN_FILE"; fi
    echo "${MEERKAT_PREFERRED_PORT:-none} ${*:3}" >> "$PORTS_FILE"
    if [[ -n "${MEERKAT_SERVE_DIR:-}" ]]; then echo "$((i + 1)) $$" > "$MEERKAT_SERVE_DIR/port"; fi
    exit "${codes[$i]:-0}"
    """)

    File.chmod!(Path.join([rel, "bin", "meerkat"]), 0o755)

    input = Keyword.get(opts, :input)
    input_file = Path.join(dir, "input")
    if input, do: File.write!(input_file, input)

    env = [
      {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
      {"SEQ_FILE", Path.join(dir, "seq")},
      {"PORTS_FILE", Path.join(dir, "ports")},
      {"STDIN_FILE", if(input, do: Path.join(dir, "stdin"))},
      {"INPUT_FILE", if(input, do: input_file, else: "/dev/null")}
    ]

    args = Keyword.get(opts, :args, ["--commit-msg", "/tmp/msg", "--no-open"])
    code = run_launcher(@shepherd, args, env, dir)
    iterations = String.to_integer(String.trim(File.read!(Path.join(dir, "i"))))

    cond do
      Keyword.get(opts, :ports) ->
        ports = File.read!(Path.join(dir, "ports")) |> String.trim() |> String.split("\n")
        %{code: code, iterations: iterations, ports: ports}

      input ->
        %{code: code, iterations: iterations, stdin: File.read!(Path.join(dir, "stdin"))}

      true ->
        %{code: code, iterations: iterations}
    end
  end

  # The dev launcher runs `mix run` as the BEAM, and `find`, `mix compile`
  # and `bunx vite build` to check and refresh the build.
  defp dev_launcher_between_runs(args \\ ["--commit-msg", "/tmp/msg", "--no-open"]) do
    port_file_between_runs(
      Path.join(File.cwd!(), "bin/meerkat-beam"),
      "stubs/mix",
      "if [[ \"$1\" != run ]]; then\n#{record_port_file("mix")}\nexit 0\nfi",
      [{"find", "/usr/bin/find"}, {"bunx", nil}],
      fn _dir -> [] end,
      args
    )
  end

  # Runs `launcher` with a fake BEAM at `beam_path` under a temp dir. The
  # BEAM records the preferred port it saw as `beam: <port>` (`beam: none`
  # if unset), writes its port file and exits 75, then 0. `stubs` shadow
  # commands the launcher runs between BEAMs: each records what
  # `record_port_file/1` does, then execs its real command, or exits 0
  # without one. `env` gets the temp dir. Returns what was recorded, in
  # order and without repeats.
  defp port_file_between_runs(
         launcher,
         beam_path,
         prelude,
         stubs,
         env,
         args \\ ["--commit-msg", "/tmp/msg", "--no-open"]
       ) do
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
    on_exit(fn -> File.rm_rf!(dir) end)

    stub_dir = Path.join(dir, "stubs")
    File.mkdir_p!(stub_dir)
    beam = Path.join(dir, beam_path)
    File.mkdir_p!(Path.dirname(beam))
    File.write!(Path.join(dir, "i"), "0")
    File.write!(Path.join(dir, "seen"), "")

    File.write!(beam, """
    #!/usr/bin/env bash
    #{prelude}
    i=$(cat "$I_FILE"); echo $((i + 1)) > "$I_FILE"
    echo "beam: ${MEERKAT_PREFERRED_PORT:-none}" >> "$SEEN_FILE"
    echo "$((i + 1)) $$" > "$MEERKAT_SERVE_DIR/port"
    if [[ "$i" == 0 ]]; then exit 75; fi
    exit 0
    """)

    File.chmod!(beam, 0o755)

    for {name, real} <- stubs do
      path = Path.join(stub_dir, name)
      exec = if real, do: ~s(exec #{real} "$@"), else: "exit 0"
      File.write!(path, "#!/usr/bin/env bash\n#{record_port_file(name)}\n#{exec}\n")
      File.chmod!(path, 0o755)
    end

    env =
      env.(dir) ++
        [
          {"PATH", stub_dir <> ":" <> System.fetch_env!("PATH")},
          {"SEEN_FILE", Path.join(dir, "seen")},
          {"INPUT_FILE", "/dev/null"}
        ]

    assert run_launcher(launcher, args, env, dir) == 0

    Path.join(dir, "seen")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.uniq()
  end

  # Once the first BEAM has run, records whether the run dir still holds a
  # `port` file, as `<name>: stale` or `<name>: none`.
  defp record_port_file(name) do
    """
    if [[ -n "${MEERKAT_SERVE_DIR:-}" && "$(cat "$I_FILE")" != 0 ]]; then
      if [[ -f "$MEERKAT_SERVE_DIR/port" ]]; then echo "#{name}: stale"; else echo "#{name}: none"; fi >> "$SEEN_FILE"
    fi\
    """
  end

  # Runs a launcher as a caller with `env`, which adds to or (with nil)
  # removes from the variables every run shares, and returns its exit code.
  defp run_launcher(launcher, args, env, dir) do
    base = [
      {"MEERKAT_PORT", "44444"},
      # A caller running inside a BEAM inherits its preference; the
      # launcher must not pass it on to its own first BEAM.
      {"MEERKAT_PREFERRED_PORT", "12345"},
      {"MEERKAT_RUNS_DIR", Path.join(dir, "runs")},
      {"I_FILE", Path.join(dir, "i")},
      # A shepherd run by a caller has this set; the caller itself does not.
      {"MEERKAT_SERVE_DIR", nil}
    ]

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
        args: ["-c", script, launcher | args],
        env: Enum.map(base ++ env, fn {k, v} -> {~c"#{k}", if(v, do: ~c"#{v}", else: false)} end)
      ])

    await_exit(port, dir)
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
