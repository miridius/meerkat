defmodule Meerkat.ShepherdTest do
  # Runs the real bin/meerkat-shepherd, through its caller half in
  # bin/meerkat-attach, against a fake release BEAM whose per-iteration
  # exit codes are scripted. This pins the exit-code contract the prod
  # launcher rests on, and the port each launcher, prod and dev, prefers
  # for its BEAMs.
  use ExUnit.Case, async: true

  import Meerkat.TestHelpers, only: [eventually: 2]

  @shepherd Path.join(File.cwd!(), "bin/meerkat-shepherd")
  # How long any wait here lasts before the test fails. It bounds only a
  # hang: a passing test stops waiting as soon as what it waits for
  # happens, which under load can take tens of seconds. It stays below
  # the 180 s test timeout, so a hang fails with this file's message.
  @timeout_ms 150_000

  # Builds, once for the module, the files tests only read: a release
  # whose BEAM runs the script a test gives as $FAKE_BEAM, the stub
  # commands, and dev checkouts. Each test keeps only what its run writes.
  setup_all do
    shared = Meerkat.TestHelpers.tmp_path("meerkat-shep-shared")

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :shared})
      File.rm_rf!(shared)
    end)

    :persistent_term.put({__MODULE__, :shared}, shared)
    build_shared(shared)
    :ok
  end

  test "restarts on exit 75, then propagates a clean decision" do
    assert run_shepherd([75, 75, 76]) == %{code: 0, iterations: 3}
  end

  test "retries a crash (exit 2) once, then propagates a clean decision" do
    assert run_shepherd([2, 76]) == %{code: 0, iterations: 2}
  end

  test "aborts (propagates 2) on a second consecutive crash" do
    assert run_shepherd([2, 2]) == %{code: 2, iterations: 2}
  end

  test "propagates a reject (exit 1) straight through" do
    assert run_shepherd([1]) == %{code: 1, iterations: 1}
  end

  test "propagates a SIGTERM halt (exit 143) straight through" do
    assert run_shepherd([143]) == %{code: 143, iterations: 1}
  end

  test "turns a BEAM exit 0, which no decision halts with, into 143" do
    assert run_shepherd([0, 76]) == %{code: 143, iterations: 1}
  end

  test "the dev launcher turns a BEAM exit 0 into 143, and its approval exit 76 into 0" do
    {port, dir, _} = open_dev_shepherd(exit_codes: [0])
    assert await_exit(port, dir) == 143

    {port, dir, _} = open_dev_shepherd(exit_codes: [76])
    assert await_exit(port, dir) == 0
  end

  test "a 75 restart resets the crash budget" do
    assert run_shepherd([2, 75, 2, 76]) == %{code: 0, iterations: 4}
  end

  test "without --port, the BEAM prefers the stable port, and a respawn the port the last BEAM bound" do
    assert run_shepherd([75, 2, 76], ports: true) == %{
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
    assert run_shepherd([75, 76], args: ["--commit-msg", "/tmp/msg", "--port", "0"], ports: true) ==
             %{
               code: 0,
               iterations: 2,
               ports: ["none --commit-msg /tmp/msg --port 0", "1 --commit-msg /tmp/msg --port 0"]
             }
  end

  test "an explicit --port=N reaches the BEAM untouched, with no stable port preferred" do
    assert run_shepherd([76], args: ["--commit-msg", "/tmp/msg", "--port=0"], ports: true) == %{
             code: 0,
             iterations: 1,
             ports: ["none --commit-msg /tmp/msg --port=0"]
           }
  end

  test "--answers runs the BEAM once with the caller's stdin" do
    input = ~s({"answers":[{"location":"global","question":"q","answer":"a"}]}\n)

    assert run_shepherd([76], args: ["--answers"], input: input) == %{
             code: 0,
             iterations: 1,
             stdin: input
           }
  end

  test "--answers turns a BEAM exit 0 into 143 with a REJECT message" do
    dir = test_dir()
    env = fake_release("exit 0\n") ++ [{"INPUT_FILE", "/dev/null"}]
    port = open_launcher(@shepherd, ["--answers"], dir, env)

    assert {143, output} = await_result(port, dir)
    assert output =~ "meerkat: the review BEAM exited 0 before meerkat decided"
  end

  test "--answers stopped by SIGTERM kills its BEAM and exits 143 without a message" do
    dir = test_dir()
    started = Path.join(dir, "beam-started")
    caller_pid_file = Path.join(dir, "caller-pid")

    port =
      open_launcher(
        @shepherd,
        ["--answers"],
        dir,
        fake_release(~S"""
        echo $$ > "$BEAM_STARTED.tmp"; mv "$BEAM_STARTED.tmp" "$BEAM_STARTED"
        exec sleep 60
        """) ++
          [
            {"BEAM_STARTED", started},
            {"CALLER_PID_FILE", caller_pid_file}
          ],
        own_group: true
      )

    beam = await_file(started)
    System.cmd("kill", ["-TERM", await_file(caller_pid_file)])

    assert await_result(port, dir) == {143, ""}
    assert await_gone(beam), "the --answers BEAM #{beam} is still running"
  end

  test "--answers propagates a crash (exit 2) without a retry" do
    assert run_shepherd([2, 0], args: ["--answers"], input: "nope") == %{
             code: 2,
             iterations: 1,
             stdin: "nope"
           }
  end

  test "a fake BEAM's port announcement cannot reach an unrelated HTTP client" do
    dir = test_dir()
    fifo = Path.join(dir, "attach-ready")
    marker = Path.join(dir, "uncontrolled-http")
    assert {_, 0} = System.cmd("mkfifo", [fifo])

    # If the caller escapes the fixture's HTTP boundary, record it and
    # release the BEAM so the test fails by assertion, not by hanging.
    File.write!(Path.join(dir, "curl"), """
    #!/usr/bin/env bash
    touch '#{marker}'
    if mkdir "$SHEPHERD_TEST_ATTACH_FIFO.sent" 2>/dev/null; then
      printf 'attach\\n' 1<> "$SHEPHERD_TEST_ATTACH_FIFO"
    fi
    printf 's 000\\n'
    exit 7
    """)

    File.chmod!(Path.join(dir, "curl"), 0o755)

    assert run_shepherd([76],
             env: [
               {"PATH", dir <> ":" <> System.fetch_env!("PATH")},
               {"SHEPHERD_TEST_ATTACH_FIFO", fifo}
             ]
           ) == %{code: 0, iterations: 1}

    assert File.dir?(fifo <> ".sent")
    refute File.exists?(marker)
  end

  for flag <- ["--answers", "--answers=true"] do
    test "the dev launcher runs #{flag} once with the caller's stdin" do
      input = ~s({"answers":[{"location":"global","question":"q","answer":"a"}]}\n)
      dir = test_dir()
      File.write!(Path.join(dir, "input"), input)

      # `mix compile` succeeds; each `mix run` records its args and stdin.
      env = [
        {"PATH", shared("answers-stubs") <> ":" <> System.fetch_env!("PATH")},
        {"RUNS_FILE", Path.join(dir, "runs-seen")},
        {"STDIN_FILE", Path.join(dir, "stdin")},
        {"INPUT_FILE", Path.join(dir, "input")}
      ]

      assert run_launcher(shared("roots/plain/bin/meerkat-beam"), [unquote(flag)], env, dir) == 0

      assert [run] =
               dir |> Path.join("runs-seen") |> File.read!() |> String.split("\n", trim: true)

      assert run =~ ~r/\Arun --no-start --no-compile -e .* -- #{unquote(flag)}\z/
      assert File.read!(Path.join(dir, "stdin")) == input
    end
  end

  # A caller that re-reads a stale `port` file reattaches to the exited
  # BEAM's port, which by then another process may hold.
  describe "between a BEAM's exit and its respawn" do
    test "the prod shepherd leaves no port file naming the exited BEAM" do
      seen = Enum.reject(prod_shepherd_between_runs(), &String.starts_with?(&1, "secret:"))
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

    test "the prod shepherd gives every BEAM it spawns one generated secret" do
      assert [<<"secret: ", secret::binary>>] =
               Enum.filter(prod_shepherd_between_runs(), &String.starts_with?(&1, "secret:"))

      assert byte_size(Base.decode64!(secret)) == 48
    end

    test "the dev launcher gives every BEAM it spawns one generated secret" do
      assert [<<"secret: ", secret::binary>>] =
               Enum.filter(dev_launcher_between_runs(), &String.starts_with?(&1, "secret:"))

      assert byte_size(Base.decode64!(secret)) == 48
    end

    test "the prod shepherd keeps an inherited secret" do
      seen = prod_shepherd_between_runs([{"SECRET_KEY_BASE", "inherited"}])
      assert Enum.filter(seen, &String.starts_with?(&1, "secret:")) == ["secret: inherited"]
    end

    test "the dev launcher keeps an inherited secret" do
      seen =
        dev_launcher_between_runs(["--commit-msg", "/tmp/msg", "--no-open"], [
          {"SECRET_KEY_BASE", "inherited"}
        ])

      assert Enum.filter(seen, &String.starts_with?(&1, "secret:")) == ["secret: inherited"]
    end
  end

  # Claude Code's sandbox denies ps, so the caller cannot tell whether the
  # process that ran it is alive, nor what a pid runs.
  test "a caller that ps cannot see keeps waiting and gets the decision" do
    dir = test_dir()

    # Decides after the caller's first checks, without binding a port.
    port =
      open_launcher(
        @shepherd,
        ["--commit-msg", "/tmp/msg", "--no-open"],
        dir,
        fake_release("sleep 1.5\nexit 76\n") ++
          [{"INPUT_FILE", "/dev/null"}, {"PATH", deny_ps_path()}]
      )

    assert await_exit(port, dir) == 0
  end

  @orphaned "outcome\nmeerkat: the process that ran meerkat exited before the review " <>
              "completed. The review is still open at http://127.0.0.1:4242/; run the " <>
              "same command again to wait for its outcome.\n"

  # Stubs a server whose attach stream sends an outcome with exit code 1,
  # then has the caller attach to it.
  @attach_to_decision ~S"""
  _MA_LINK="$2/run"
  _MA_DIR="$2/run.1"
  mkdir "$_MA_DIR"
  echo "4242 1" >"$_MA_DIR/port"
  echo token >"$_MA_DIR/token"
  echo 1 >"$_MA_DIR/exit"
  _ma_request() {
    case "$2" in
      attach/delivered*) echo delivered ;;
      *) printf 'k\no outcome\nx 1\ns 200\n' ;;
    esac
  }
  _ma_attach
  """

  # A killed git commit can leave its hook's caller attached. Once the
  # decision arrives, that caller leaves it held for the next invocation
  # instead of taking delivery where nobody reads it. An ancestor whose pid
  # a live process has since taken ("reused") is gone too. Where ps is
  # denied ("unseen"), it cannot tell, so it takes delivery.
  for ancestor <- ["reused", "live", "unseen"] do
    test "a caller given the decision takes delivery only while its ancestors live: #{ancestor}" do
      dir = test_dir()

      script =
        ~S"""
        source "$1"
        exec 2>&1
        _ma_record_ancestors
        case "$3" in
          reused)
            sleep 30 &
            reused=$!
            trap 'kill "$reused"' EXIT
            _MA_ANCESTORS=("$reused" "${_MA_ANCESTORS[@]}")
            ;;
          unseen)
            sleep 0 &
            gone=$!
            wait "$gone"
            _MA_ANCESTORS=("$gone") && ps() { return 1; }
            ;;
        esac
        """ <> @attach_to_decision

      {output, 1} =
        System.cmd("bash", [
          "-c",
          script,
          "orphan",
          Path.expand("bin/meerkat-attach"),
          dir,
          unquote(ancestor)
        ])

      if unquote(ancestor) in ["live", "unseen"] do
        assert output == "outcome\ndelivered\n"
      else
        assert output == @orphaned
      end
    end
  end

  # The caller's parent really exits, as a killed git commit does, so the
  # caller is reparented and the chain above it changes.
  test "a caller given the decision after its parent exited leaves the decision held" do
    dir = test_dir()

    caller =
      ~S"""
      source "$1"
      exec 2>&1
      _ma_record_ancestors
      parent=$PPID
      touch "$2/recorded"
      while [[ "$(ps -o ppid= -p $$ | tr -d ' ')" == "$parent" ]]; do
        ((SECONDS < 60)) || { echo "the parent never exited"; exit 1; }
        sleep 0.05
      done
      """ <> @attach_to_decision

    # The parent starts the caller, waits for it to record its ancestors,
    # and exits. System.cmd still collects the caller's output: it waits for
    # EOF on the stdout the caller inherited.
    parent = ~S"""
    bash -c "$1" caller "$2" "$3" &
    c=$!
    until [[ -f "$3/recorded" ]] || ! kill -0 "$c" 2>/dev/null; do
      ((SECONDS < 60)) || exit 1
      sleep 0.05
    done
    [[ -f "$3/recorded" ]] || { echo "the caller died before recording"; exit 1; }
    """

    {output, 0} =
      System.cmd("bash", [
        "-c",
        parent,
        "parent",
        caller,
        Path.expand("bin/meerkat-attach"),
        dir
      ])

    assert output == @orphaned
  end

  # A caller relays its backend's log as it grows: from the start for a run
  # it started, even one with no log yet, and from the end on reattach.
  test "a caller relays each part of its backend's log once" do
    dir = test_dir()

    script = ~S"""
    source "$1"
    exec 2>&1
    _MA_LOG_FD=""
    _MA_DIR="$2/started"
    mkdir "$_MA_DIR"
    _ma_open_log || echo "no log yet"
    _ma_relay_log
    printf '%s\n%s' ' a\b' part >"$_MA_DIR/log"
    _ma_relay_log
    printf 'ial\n' >>"$_MA_DIR/log"
    _ma_relay_log
    _ma_relay_log
    _MA_DIR="$2/reattached"
    mkdir "$_MA_DIR"
    printf 'seen\n' >"$_MA_DIR/log"
    _ma_open_log && _ma_read_log >/dev/null
    printf 'b\n' >>"$_MA_DIR/log"
    _ma_relay_log
    printf 'a\npartial\n' >>"$2/started/log"
    _ma_relay_log
    """

    assert {"no log yet\n a\\b\npartial\nb\n", 0} =
             System.cmd("bash", ["-c", script, "relay", Path.expand("bin/meerkat-attach"), dir])
  end

  # After a 409 or 503 the caller starts a fresh backend, whose stderr it
  # relays rather than the last run's log.
  test "a caller relays the log of the backend it starts, not the last run's" do
    dir = test_dir()
    File.write!(Path.join(dir, "self"), "#!/bin/sh\necho new >&2\n")
    File.chmod!(Path.join(dir, "self"), 0o755)

    script = ~S"""
    source "$1"
    exec 2>&1
    exec {_MA_ERR}>&2
    _MA_LOG_FD=""
    _MA_RUN=run
    _MA_LINK="$2/run"
    _MA_DIR="$2/old"
    mkdir "$_MA_DIR"
    printf 'old\n' >"$_MA_DIR/log"
    _ma_open_log && _ma_read_log >/dev/null
    _ma_start_server "$2/self"
    until [[ -s "$_MA_DIR/log" ]]; do sleep 0.05; done
    _ma_relay_log
    """

    assert {"new\n", 0} =
             System.cmd("bash", ["-c", script, "restart", Path.expand("bin/meerkat-attach"), dir])
  end

  # A waiting caller relays its backend's log every 0.2 s tick and checks
  # its ancestors only once the decision arrives, so it forks nothing per
  # tick. The backend writes each next line only once the test has seen
  # the last one relayed, so the quiet stream spans at least five relays,
  # each on its own tick.
  test "a caller waiting on a decision runs no process while it relays the backend's log" do
    dir = test_dir()

    release =
      fake_release(~S"""
      echo "1 $$" > "$MEERKAT_SERVE_DIR/port"
      # The backend runs in its own session, so a failed test cannot kill it;
      # it exits once the test's own waits (@timeout_ms) are surely over.
      for k in {1..6}; do
        echo "tick $k" >&2
        until [[ -f "$ACKS/$k" ]]; do ((SECONDS < 200)) || exit 1; sleep 0.05; done
      done
      until [[ -f "$DELIVERED" ]]; do ((SECONDS < 200)) || exit 1; sleep 0.05; done
      """)

    # The attach stream stays quiet until the test has seen every tick.
    curl = ~S"""
    #!/usr/bin/env bash
    case "$*" in
      *attach/delivered*) touch "$DELIVERED"; exit 0 ;;
    esac
    echo start >> "$CALLS"
    printf 'k\n'
    until [[ -f "$ACKS/6" ]]; do ((SECONDS < 200)) || exit 1; sleep 0.05; done
    echo end >> "$CALLS"
    printf 'x 0\ns 200\n'
    """

    calls = Path.join(dir, "calls")
    acks = Path.join(dir, "acks")
    File.mkdir_p!(acks)

    port =
      open_launcher(
        @shepherd,
        ["--commit-msg", "/tmp/msg", "--no-open"],
        dir,
        release ++
          [
            {"INPUT_FILE", "/dev/null"},
            {"CALLS", calls},
            {"ACKS", acks},
            {"DELIVERED", Path.join(dir, "delivered")},
            # Each logs its run to $CALLS, then runs the real command.
            {"PATH", shared("logged") <> ":" <> System.get_env("PATH")}
          ],
        curl: curl
      )

    for k <- 1..6 do
      await_output(port, dir, "tick #{k}\n")
      File.touch!(Path.join(acks, "#{k}"))
    end

    assert {0, _} = await_result(port, dir)

    idle =
      calls
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.drop_while(&(&1 != "start"))
      |> Enum.take_while(&(&1 != "end"))

    assert idle == ["start"]
  end

  # macOS deletes files in $TMPDIR more than three days old, and the
  # shepherd writes `token` and `pid` only once. A caller reattaching after
  # a restart then could not authenticate, took the backend for dead,
  # killed its BEAM and rejected the commit.
  test "a review whose token and pid files are deleted gets them back when its BEAM restarts" do
    dir = test_dir()
    File.write!(Path.join(dir, "i"), "0")

    # The first BEAM deletes both files and asks for a restart; the second
    # approves only if both are back as they were.
    env =
      fake_release(~S"""
      i=$(cat "$I_FILE"); echo $((i + 1)) > "$I_FILE"
      if [[ "$i" == 0 ]]; then
        cp "$MEERKAT_SERVE_DIR/token" "$TOKEN_SEEN"
        rm "$MEERKAT_SERVE_DIR/token" "$MEERKAT_SERVE_DIR/pid"
        exit 75
      fi
      cmp -s "$TOKEN_SEEN" "$MEERKAT_SERVE_DIR/token" || exit 1
      [[ "$(cat "$MEERKAT_SERVE_DIR/pid")" == "$PPID" ]] || exit 1
      exit 76
      """) ++ [{"TOKEN_SEEN", Path.join(dir, "token-seen")}, {"INPUT_FILE", "/dev/null"}]

    assert run_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], env, dir) == 0
  end

  test "a review keeps its run dir and browser-open marker out of $TMPDIR" do
    dir = test_dir()

    env =
      fake_release(~S"""
      echo "$MEERKAT_SERVE_DIR $MEERKAT_OPEN_MARKER" > "$SEEN_FILE"
      exit 76
      """) ++
        [
          {"MEERKAT_RUNS_DIR", nil},
          {"XDG_STATE_HOME", Path.join(dir, "state")},
          {"TMPDIR", Path.join(dir, "tmp")},
          {"SEEN_FILE", Path.join(dir, "seen")},
          {"INPUT_FILE", "/dev/null"}
        ]

    assert run_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], env, dir) == 0
    [serve_dir, marker] = dir |> Path.join("seen") |> File.read!() |> String.split()
    assert Path.dirname(serve_dir) == Path.join([dir, "state", "meerkat", "runs"])
    assert marker == Path.join(serve_dir, "opened")
    refute File.exists?(Path.join(dir, "tmp"))
  end

  @rerun "Run the same command again.\n"
  @still_open "The review is still open at http://127.0.0.1:1/; run the same command again to wait for its outcome.\n"
  @serves ~S|touch "$MEERKAT_SERVE_DIR/served"; echo "1 $$" >"$MEERKAT_SERVE_DIR/port"|

  # A BEAM that never binds, so the review has no URL yet, one between
  # BEAMs, which has served the review but has no port, or one that has
  # bound, whose answer to the caller's leave is `leave` (curl's output, then
  # its exit status). It says when it has started: a shepherd stopped before
  # it traps signals dies without recording an exit code. The signal goes to
  # the caller's whole process group, so it also kills whatever the caller
  # is running at the time.
  for {signal, number, backend, beam, leave, stopped?, said} <- [
        {"TERM", 15, "starts", "", "", true, @rerun},
        {"INT", 2, "starts", "", "", true, @rerun},
        {"HUP", 1, "starts", "", "", true, @rerun},
        {"TERM", 15, "is between BEAMs", ~S|touch "$MEERKAT_SERVE_DIR/served"|, "", false,
         @rerun},
        # Times out only when told to give up after 2 s, so a caller that
        # stopped passing --max-time 2 would leave the server running.
        {"TERM", 15, "does not answer within 2 s", @serves,
         ~S|[[ " $* " == *" --max-time 2 "* ]] && exit 28; exit 0|, true, @rerun},
        {"TERM", 15, "answers with an error", @serves, "exit 22", false, @rerun},
        {"TERM", 15, "answers that the review ended", @serves, "echo ended; exit 0", false,
         @rerun},
        {"TERM", 15, "answers that the review is open", @serves, "echo open; exit 0", false,
         @still_open}
      ] do
    test "a caller whose process group gets SIG#{signal} while its backend #{backend} #{if stopped?, do: "stops", else: "leaves"} it, prints only what to do and dies of the signal" do
      dir = test_dir()
      started = Path.join(dir, "beam-started")
      caller_pid_file = Path.join(dir, "caller-pid")
      kills = Path.join(dir, "kills")

      port =
        open_launcher(
          @shepherd,
          ["--commit-msg", "/tmp/msg", "--no-open"],
          dir,
          fake_release("#{unquote(beam)}\ntouch \"$BEAM_STARTED\"\nexec sleep 60\n") ++
            [
              {"BEAM_STARTED", started},
              {"CALLER_PID_FILE", caller_pid_file},
              # Every kill the launcher's bash runs is logged before it is sent,
              # so whether the caller stopped the backend is known once it exits.
              {"KILLS", kills},
              {"BASH_FUNC_kill%%", ~S|() { echo "$*" >>"$KILLS"; builtin kill "$@"; }|}
            ],
          own_group: true,
          # The attach never connects, so the caller keeps trying until stopped.
          curl: """
          #!/usr/bin/env bash
          if [[ "$*" == *attach/leave* ]]; then #{unquote(leave)}; fi
          printf 's 000\\n'
          exit 7
          """
        )

      runs = Path.join(dir, "runs")
      backend = await_backend_pid(runs)

      # The shepherd's EXIT trap writes `exit` into its run dir after the
      # TERM; deleting the dir before then races that write. Not every run
      # dir gets an `exit`, so each wait gets 10 s, not @timeout_ms: several
      # full waits would outlast ExUnit's 180 s on_exit limit.
      on_exit(fn ->
        System.cmd("kill", ["-TERM", backend], stderr_to_stdout: true)

        for run <- Path.wildcard(Path.join(runs, "*")),
            do: await_file(Path.join(run, "exit"), 10_000)
      end)

      assert await_file(started) == ""
      System.cmd("kill", ["-#{unquote(signal)}", "-" <> await_file(caller_pid_file)])

      assert {code, output} = await_result(port, dir)
      assert code == 128 + unquote(number)

      assert output ==
               "meerkat: stopped waiting (SIG#{unquote(signal)}) before the review completed. " <>
                 unquote(said)

      assert "-TERM #{backend}" in String.split(File.read!(kills), "\n") == unquote(stopped?)

      if unquote(stopped?) do
        [run] = Path.wildcard(Path.join(runs, "*.*"))
        assert await_file(Path.join(run, "exit")) == "143"
      end
    end
  end

  # The caller signals itself from the `kill -0 ... 2>/dev/null` of a poll,
  # so its trap runs while its stderr goes to /dev/null.
  test "a caller stopped while a command's stderr is discarded still says how the review stands" do
    dir = test_dir()
    runs = Path.join(dir, "runs")
    started = Path.join(dir, "beam-started")
    trigger = Path.join(dir, "trigger")

    port =
      open_launcher(
        @shepherd,
        ["--commit-msg", "/tmp/msg", "--no-open"],
        dir,
        fake_release("#{@serves}\ntouch \"$BEAM_STARTED\"\nexec sleep 60\n") ++
          [
            {"BEAM_STARTED", started},
            {"CALLER_PID_FILE", Path.join(dir, "caller-pid")},
            {"TRIGGER", trigger},
            {"BASH_FUNC_kill%%",
             ~S|() { if [[ "$1" == -0 ]] && rm "$TRIGGER" 2>/dev/null; then builtin kill -TERM $$; fi; builtin kill "$@"; }|}
          ],
        own_group: true,
        curl: """
        #!/usr/bin/env bash
        if [[ "$*" == *attach/leave* ]]; then echo open; exit 0; fi
        printf 's 000\\n'
        exit 7
        """
      )

    backend = await_backend_pid(runs)

    on_exit(fn ->
      System.cmd("kill", ["-TERM", backend], stderr_to_stdout: true)

      for run <- Path.wildcard(Path.join(runs, "*")),
          do: await_file(Path.join(run, "exit"), 10_000)
    end)

    assert await_file(started) == ""
    File.write!(trigger, "")

    assert {143, output} = await_result(port, dir)

    assert output ==
             "meerkat: stopped waiting (SIGTERM) before the review completed. " <> @still_open
  end

  # The attach never connects, so neither caller hears from the backend; a leave
  # is logged and answered as if it ended the review.
  for {shown, beam} <- [{"has not shown", ""}, {"has shown", @serves}] do
    test "a rerun stopped before it hears from a backend that #{shown} the review only hands it back to the caller it replaced" do
      dir = test_dir()
      runs = Path.join(dir, "runs")
      rerun_pid_file = Path.join(dir, "rerun-pid")
      kills = Path.join(dir, "kills")
      leaves = Path.join(dir, "leaves")

      env =
        fake_release("#{unquote(beam)}\nexec sleep 60\n") ++
          [{"INPUT_FILE", "/dev/null"}, {"LEAVES", leaves}]

      curl = ~S"""
      #!/usr/bin/env bash
      if [[ "$*" == *attach/leave* ]]; then echo "$*" >>"$LEAVES"; echo ended; exit 0; fi
      printf 's 000\n'
      exit 7
      """

      first =
        open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, env, curl: curl)

      {:os_pid, first_pid} = Port.info(first, :os_pid)
      backend = await_backend_pid(runs)

      # Killed outright, the first caller cannot remove the run while it is
      # deleted; the backend's exit file is written before then.
      on_exit(fn ->
        System.cmd("kill", ["-KILL", to_string(first_pid)], stderr_to_stdout: true)
        System.cmd("kill", ["-TERM", backend], stderr_to_stdout: true)

        for run <- Path.wildcard(Path.join(runs, "*.*")),
            do: await_file(Path.join(run, "exit"), 10_000)
      end)

      rerun =
        open_launcher(
          @shepherd,
          ["--commit-msg", "/tmp/msg", "--no-open"],
          dir,
          env ++
            [
              {"CALLER_PID_FILE", rerun_pid_file},
              {"KILLS", kills},
              {"BASH_FUNC_kill%%", ~S|() { echo "$*" >>"$KILLS"; builtin kill "$@"; }|}
            ],
          own_group: true,
          curl: curl
        )

      rerun_pid = await_file(rerun_pid_file)
      [caller] = Path.wildcard(Path.join([runs, "*.*", "caller"]))
      assert eventually(fn -> File.read!(caller) == "#{rerun_pid}\n" end, timeout: @timeout_ms)
      System.cmd("kill", ["-TERM", "-" <> rerun_pid])

      assert {143, output} = await_result(rerun, dir)

      assert output ==
               "meerkat: stopped waiting (SIGTERM) before the review completed. Run the same command again.\n"

      assert File.read!(caller) == "#{first_pid}\n"
      refute "-TERM #{backend}" in String.split(File.read!(kills), "\n")
      refute File.exists?(leaves)
    end
  end

  describe "when a review's backend is killed and the review rerun at once" do
    # Where ps is denied, the rerun cannot tell the first caller is alive
    # and must still leave it its run.
    for {where, deny_ps} <- [{"", false}, {" where ps is denied", true}] do
      test "its caller gets that backend's exit code, not the rerun's#{where}" do
        review = open_killable_review(unquote(deny_ps))

        # Holds the first caller still, so the rerun runs in the window
        # between the backend's exit and the first caller's next look.
        System.cmd("kill", ["-STOP", review.first_pid])

        on_exit(fn ->
          System.cmd("kill", ["-CONT", review.first_pid], stderr_to_stdout: true)
        end)

        second = kill_backend_and_rerun(review)
        System.cmd("kill", ["-CONT", review.first_pid])
        File.write!(review.go, "")

        assert await_exit(review.first, review.dir) == 143
        assert await_exit(second, review.dir) == 7
        assert File.ls!(review.runs) == []
      end
    end

    test "a rerun removes the run dir its killed caller left" do
      review = open_killable_review()
      System.cmd("kill", ["-KILL", review.first_pid])
      await_exit(review.first, review.dir)

      second = kill_backend_and_rerun(review)
      File.write!(review.go, "")

      assert await_exit(second, review.dir) == 7
      assert File.ls!(review.runs) == []
    end

    test "a caller back over a minute after its run finished, rerun meanwhile, exits 2" do
      # With ps denied, only the exit file's age lets the rerun reap the run.
      review = open_killable_review(true)
      System.cmd("kill", ["-STOP", review.first_pid])

      on_exit(fn ->
        System.cmd("kill", ["-CONT", review.first_pid], stderr_to_stdout: true)
      end)

      System.cmd("kill", ["-TERM", review.backend])
      await_match(Path.join([review.runs, "*.*", "exit"]))
      [exit] = Path.wildcard(Path.join([review.runs, "*.*", "exit"]))
      File.touch!(exit, System.os_time(:second) - 120)

      second =
        open_launcher(
          @shepherd,
          ["--commit-msg", "/tmp/msg", "--no-open"],
          review.dir,
          review.env
        )

      await_backend_pid(review.runs, [review.backend])
      System.cmd("kill", ["-CONT", review.first_pid])
      File.write!(review.go, "")

      assert {2, output} = await_result(review.first, review.dir)
      assert output =~ "was removed — defaulting to REJECT (commit aborted)."
      assert await_exit(second, review.dir) == 7
    end
  end

  describe "a reattach whose server exits before it hears from it" do
    test "starts a new review instead of taking that exit code" do
      review = open_killable_review()
      System.cmd("kill", ["-KILL", review.first_pid])
      await_exit(review.first, review.dir)

      # Reattaches while the first BEAM, which never binds, runs.
      second =
        open_launcher(
          @shepherd,
          ["--commit-msg", "/tmp/msg", "--no-open"],
          review.dir,
          review.env
        )

      {:os_pid, second_pid} = Port.info(second, :os_pid)
      [run] = Path.wildcard(Path.join(review.runs, "*.*"))
      assert await_content(Path.join(run, "caller"), to_string(second_pid))

      System.cmd("kill", ["-TERM", review.backend])
      await_backend_pid(review.runs, [review.backend])
      File.write!(review.go, "")

      assert await_exit(second, review.dir) == 7
      assert File.ls!(review.runs) == []
    end
  end

  describe "an older meerkat's run dir at the review's key" do
    test "is removed once finished, and the caller starts a new run" do
      dir = test_dir()
      old = Path.join([dir, "runs", run_key(dir)])
      File.mkdir_p!(old)
      File.write!(Path.join(old, "exit"), "5\n")
      env = fake_release("exit 76\n") ++ [{"MEERKAT_PWD", dir}, {"INPUT_FILE", "/dev/null"}]

      assert run_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], env, dir) == 0
      assert File.ls!(Path.join(dir, "runs")) == []
    end

    test "is found by a caller in a subdirectory of the work tree, whose BEAM prefers the review's port" do
      dir = Meerkat.TestHelpers.make_git_repo("meerkat-shep")
      on_exit(fn -> File.rm_rf!(dir) end)
      sub = Path.join(dir, "src")
      File.mkdir_p!(sub)
      fake_release(dir, ~s(echo "$MEERKAT_PREFERRED_PORT" > "$PORT_SEEN"\nexit 76\n))
      old = Path.join([dir, "runs", run_key(dir)])
      File.mkdir_p!(old)
      File.write!(Path.join(old, "exit"), "5\n")

      env = [
        {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
        {"MEERKAT_PWD", sub},
        {"MEERKAT_PORT", nil},
        {"PORT_SEEN", Path.join(dir, "port-seen")},
        {"INPUT_FILE", "/dev/null"}
      ]

      assert run_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], env, dir) == 0
      assert File.ls!(Path.join(dir, "runs")) == []
      {hex8, _} = dir |> run_key() |> binary_part(0, 8) |> Integer.parse(16)
      assert File.read!(Path.join(dir, "port-seen")) == "#{rem(hex8, 20_000) + 40_000}\n"
    end

    test "is left in place when a caller drops a run the key no longer names" do
      dir = test_dir()
      old = Path.join(dir, "key")
      File.mkdir_p!(old)

      {_, 0} = attach_shell(~S(_MA_LINK="$2"; _MA_RUN=r; _ma_retire "$2.finished"), old)

      refute File.exists?(old <> ".retiring.r")
      assert File.dir?(old) and not match?({:ok, _}, File.read_link(old))
    end
  end

  describe "once the review is removed" do
    test "a caller whose runs dir is deleted exits 2 instead of retrying" do
      dir = test_dir()
      runs = Path.join(dir, "runs")
      started = Path.join(dir, "beam-started")

      # A BEAM that never binds, so the caller keeps polling its run dir.
      # It says when it starts: until then the shepherd writes to the run
      # dir, which would race deleting it.
      port =
        open_launcher(
          @shepherd,
          ["--commit-msg", "/tmp/msg", "--no-open"],
          dir,
          fake_release("touch \"$BEAM_STARTED\"\nexec sleep 60\n") ++
            [{"BEAM_STARTED", started}, {"INPUT_FILE", "/dev/null"}]
        )

      backend = await_backend_pid(runs)
      on_exit(fn -> System.cmd("kill", ["-TERM", backend], stderr_to_stdout: true) end)
      assert await_file(started) == ""

      File.rm_rf!(runs)

      assert await_exit(port, dir) == 2
    end

    test "a caller whose backend dies exits 2, rejecting the commit, and stops the BEAM it left" do
      dir = test_dir()
      runs = Path.join(dir, "runs")

      # A BEAM that records its port, as a serving one does, on a port
      # nothing listens on, and runs until killed or for a minute. It
      # loops rather than exec'ing sleep: the caller kills only a process
      # whose command line names meerkat.
      release =
        fake_release(~S"""
        echo "1 $$" > "$MEERKAT_SERVE_DIR/port"
        for _ in {1..60}; do sleep 1; done
        """)

      port =
        open_launcher(
          @shepherd,
          ["--commit-msg", "/tmp/msg", "--no-open"],
          dir,
          release ++ [{"INPUT_FILE", "/dev/null"}]
        )

      backend = await_backend_pid(runs)
      beam = await_beam_pid(runs)

      on_exit(fn -> System.cmd("kill", ["-KILL", beam], stderr_to_stdout: true) end)

      System.cmd("kill", ["-KILL", backend])

      assert {2, output} = await_result(port, dir)

      assert output =~
               "meerkat: the review backend died without a decision — defaulting to REJECT (commit aborted)."

      assert await_gone(beam), "the BEAM #{beam} its backend left is still running"
    end

    test "a backend stopped by SIGTERM kills its BEAM and records 143" do
      dir = test_dir()
      runs = Path.join(dir, "runs")

      # A BEAM that outlives await_gone's wait unless the backend kills it.
      release =
        fake_release(~S"""
        echo "1 $$" > "$MEERKAT_SERVE_DIR/port"
        for _ in {1..600}; do sleep 1; done
        """)

      port =
        open_launcher(
          @shepherd,
          ["--commit-msg", "/tmp/msg", "--no-open"],
          dir,
          release ++ [{"INPUT_FILE", "/dev/null"}]
        )

      backend = await_backend_pid(runs)
      beam = await_beam_pid(runs)
      on_exit(fn -> System.cmd("kill", ["-KILL", beam], stderr_to_stdout: true) end)

      System.cmd("kill", ["-TERM", backend])

      assert await_exit(port, dir) == 143
      assert await_gone(beam), "the BEAM #{beam} its backend left is still running"
    end

    # As when the caller was suspended after _ma_server_alive found the pid
    # file, and meanwhile the backend finished and a rerun removed the run:
    # the backend did decide, so the next pass says the run was removed.
    test "a caller whose run is removed after its pid check does not say its backend died" do
      runs = Meerkat.TestHelpers.tmp_path("meerkat-bury")
      File.mkdir_p!(runs)
      on_exit(fn -> File.rm_rf!(runs) end)

      {out, 0} =
        attach_shell(
          ~S"""
          _MA_LINK="$2/key"; _MA_DIR="$2/key.r"; _MA_OWNED=1; _MA_HELD=1
          _ma_bury_server 2>&1; echo "next pass"
          """,
          runs
        )

      assert out == "next pass\n"
    end

    # The same removal, landing while the caller checks what runs on the
    # BEAM's pid.
    test "a caller whose run is removed while it checks the BEAM does not say its backend died" do
      runs = Meerkat.TestHelpers.tmp_path("meerkat-bury")
      File.mkdir_p!(Path.join(runs, "key.r"))
      File.write!(Path.join([runs, "key.r", "port"]), "4242 999999\n")
      on_exit(fn -> File.rm_rf!(runs) end)

      {out, 0} =
        attach_shell(
          ~S"""
          _MA_LINK="$2/key"; _MA_DIR="$2/key.r"; _MA_OWNED=1; _MA_HELD=1
          _ma_runs_meerkat() { rm -rf "$_MA_DIR"; return 1; }
          _ma_bury_server 2>&1; echo "next pass"
          """,
          runs
        )

      assert out == "next pass\n"
    end

    # An unreadable pid file fails the read the way one removed after the
    # check does, so the caller takes the backend for dead without a bash
    # error.
    test "a caller whose pid file cannot be read after its check takes the backend for dead quietly" do
      run = Meerkat.TestHelpers.tmp_path("meerkat-pid-read")
      on_exit(fn -> File.rm_rf!(run) end)
      File.mkdir_p!(run)
      File.write!(Path.join(run, "pid"), "#{System.pid()}\n")
      File.chmod!(Path.join(run, "pid"), 0o000)

      {out, 0} =
        attach_shell(~S(_MA_DIR="$2"; _ma_server_alive 2>&1; echo "alive=$?"), run)

      assert out == "alive=1\n"
    end

    test "a caller that cannot create its run dir exits 2 instead of retrying" do
      dir = test_dir()
      runs = Path.join(dir, "runs")
      File.mkdir_p!(runs)
      File.chmod!(runs, 0o555)

      on_exit(fn -> File.chmod!(runs, 0o755) end)

      port =
        open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, [
          {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
          {"INPUT_FILE", "/dev/null"}
        ])

      assert await_exit(port, dir) == 2
    end

    test "a caller whose runs dir cannot be changed exits 2 instead of spinning" do
      dir = test_dir()
      runs = Path.join(dir, "runs")
      File.mkdir_p!(runs)
      # Names a finished run that is gone.
      File.ln_s!(run_key(dir) <> ".gone", Path.join(runs, run_key(dir)))
      File.chmod!(runs, 0o555)

      on_exit(fn -> File.chmod!(runs, 0o755) end)

      port =
        open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, [
          {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
          {"MEERKAT_PWD", dir},
          {"INPUT_FILE", "/dev/null"}
        ])

      assert {2, output} = await_result(port, dir)

      assert output =~
               "meerkat: could not update #{runs} — defaulting to REJECT (commit aborted)."
    end

    test "a caller that cannot remove a finished run exits 2 at once" do
      dir = test_dir()
      runs = Path.join(dir, "runs")
      # A finished run whose caller is gone; its own dir stays writable, so
      # removing it empties it but cannot delete it.
      finished = Path.join(runs, run_key(dir) <> ".finished")
      File.mkdir_p!(finished)

      for {name, body} <- [{"exit", "143"}, {"caller", "999999"}, {"token", "t"}],
          do: File.write!(Path.join(finished, name), body <> "\n")

      File.chmod!(runs, 0o555)

      on_exit(fn -> File.chmod!(runs, 0o755) end)

      port =
        open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, [
          {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
          {"MEERKAT_PWD", dir},
          {"INPUT_FILE", "/dev/null"}
        ])

      assert {2, output} = await_result(port, dir)

      assert output ==
               "meerkat: could not update #{runs} — defaulting to REJECT (commit aborted).\n"
    end

    test "a caller that cannot remove the run it found dead says so" do
      dir = test_dir()
      runs = emptied_run(dir)
      File.chmod!(runs, 0o555)

      on_exit(fn -> File.chmod!(runs, 0o755) end)

      port =
        open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, [
          {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
          {"MEERKAT_PWD", dir},
          {"INPUT_FILE", "/dev/null"}
        ])

      # The caller waits 10 s for the backend's pid before burying it.
      assert {2, output} = await_result(port, dir)

      assert output =~
               "meerkat: could not update #{runs} — defaulting to REJECT (commit aborted).\n"
    end

    test "a caller whose polls run slow, as under load, still waits about 10 s for a missing pid" do
      dir = test_dir()
      emptied_run(dir)
      # Every `sleep` takes a second and is logged, so a wait that counted
      # its 0.2 s polls would sleep 50 times; one by the clock sleeps about
      # 10 times, and fewer under load. Load only lengthens the wait, so
      # its time has a lower bound only.
      sleeps = Path.join(dir, "sleeps")

      port =
        open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, [
          {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
          {"MEERKAT_PWD", dir},
          {"INPUT_FILE", "/dev/null"},
          {"SLEEPS", sleeps},
          {"PATH", shared("slow") <> ":" <> System.fetch_env!("PATH")}
        ])

      started = System.monotonic_time(:millisecond)
      assert {2, output} = await_result(port, dir)
      # Whole-second SECONDS makes the 10 s wait 9-10 s.
      assert System.monotonic_time(:millisecond) - started >= 8_000
      assert sleeps |> File.read!() |> String.split("\n", trim: true) |> length() <= 12

      assert output =~
               "meerkat: the review backend died without a decision — defaulting to REJECT (commit aborted)."
    end

    test "a caller whose pid wait started for one run gives the next run it finds a fresh wait" do
      runs = Meerkat.TestHelpers.tmp_path("meerkat-pid-wait")
      on_exit(fn -> File.rm_rf!(runs) end)
      File.mkdir_p!(Path.join(runs, "key.old"))
      File.mkdir_p!(Path.join(runs, "key.new"))
      File.ln_s!("key.new", Path.join(runs, "key"))

      # The caller waits for key.old's pid, then a minute passes, as when its
      # review ran and a 409 sent it back to find the key's next run.
      {out, 0} =
        attach_shell(
          ~S"""
          _MA_LINK="$2/key"; _MA_DIR="$2/key.old"
          _ma_server_alive; SECONDS=60; _ma_find_server
          if _ma_server_alive; then echo "waits for $_MA_DIR"; else echo "buries $_MA_DIR"; fi
          """,
          runs
        )

      assert out == "waits for #{runs}/key.new\n"
    end

    test "a caller whose run's pid appeared gives that pid a fresh wait if it goes missing later" do
      run = Meerkat.TestHelpers.tmp_path("meerkat-pid-wait")
      on_exit(fn -> File.rm_rf!(run) end)
      File.mkdir_p!(run)

      # The pid comes late, then the review runs a minute and loses it, as
      # meerkat_restore_run_files allows for. This shell, running
      # meerkat-attach, passes for the backend.
      {out, 0} =
        attach_shell(
          ~S"""
          _MA_DIR="$2"
          _ma_server_alive; echo $$ >"$2/pid"; _ma_server_alive
          rm "$2/pid"; SECONDS=60
          if _ma_server_alive; then echo waits; else echo buries; fi
          """,
          run
        )

      assert out == "waits\n"
    end

    test "the dev shepherd propagates a crash (exit 2)" do
      {port, dir, _} = open_dev_shepherd(exit_codes: [2, 0])

      assert await_exit(port, dir) == 2
      assert File.read!(Path.join(dir, "i")) |> String.trim() == "1"
    end

    test "the dev shepherd compiles a build that looks fresh but was compiled in another checkout" do
      {port, dir, root} = open_dev_shepherd(compile_code: 1, built: "/elsewhere")

      assert await_exit(port, dir) == 2
      assert File.read!(Path.join(root, "_build/dev/.meerkat-root")) == "/elsewhere\n"
    end

    for {failed, opts} <- [
          compile: [compile_code: 1],
          "asset build": [built: :root, build_code: 1]
        ] do
      test "the dev shepherd exits 2 with a REJECT message, starting no BEAM, after a failed #{failed}" do
        {port, dir, _} = open_dev_shepherd(unquote(opts) ++ [exit_codes: [0]])

        {code, out} = await_result(port, dir)
        assert code == 2
        assert out =~ "meerkat: the build failed — defaulting to REJECT (commit aborted)."
        assert File.read!(Path.join(dir, "i")) == "0"
      end
    end

    test "a successful compile stamps the build with its checkout" do
      {port, dir, root} = open_dev_shepherd(built: "/elsewhere", exit_codes: [76])

      assert await_exit(port, dir) == 0

      assert File.read!(Path.join(root, "_build/dev/.meerkat-root")) == root <> "\n"
    end

    test "the dev shepherd skips `mix compile` for a fresh build compiled in its own checkout" do
      {port, dir, _} = open_dev_shepherd(compile_code: 1, built: :root, exit_codes: [76])

      assert await_exit(port, dir) == 0
    end
  end

  # The fake BEAM of `port_file_between_runs/4`. It records the preferred
  # port it saw as `beam: <port>` (`beam: none` if unset) and its
  # SECRET_KEY_BASE as `secret: <value>`, writes its port file and exits
  # 75, then 76, approving.
  @between_beam ~S"""
  i=$(cat "$I_FILE"); echo $((i + 1)) > "$I_FILE"
  echo "beam: ${MEERKAT_PREFERRED_PORT:-none}" >> "$SEEN_FILE"
  echo "secret: ${SECRET_KEY_BASE:-none}" >> "$SEEN_FILE"
  echo "$((i + 1)) $$" > "$MEERKAT_SERVE_DIR/port"
  if [[ "$i" == 0 ]]; then exit 75; fi
  exit 76
  """

  defp build_shared(shared) do
    # The release every prod test runs. Its BEAM is the script in
    # $FAKE_BEAM, run by this bash so that its args, `$$` and `exec` are
    # the BEAM's own.
    executable(Path.join(shared, "rel/bin/meerkat"), ~s(#!/usr/bin/env bash\neval "$FAKE_BEAM"\n))
    File.ln_s!(Path.join(shared, "rel"), Path.join(shared, "current"))

    # These BEAMs announce scripted ports but never serve HTTP. The caller
    # can catch a port file before the BEAM exits; a real curl would then
    # contact an unrelated service or wait indefinitely for a connection.
    # Refuse at that external boundary, keeping the caller, detach, restart
    # and exit-file delivery real. The FIFO makes that window deterministic
    # in the regression above without a delay or polling loop. The BEAM
    # opens its reader before announcing the port, so the signal cannot be
    # lost. Read/write opens and a bounded read also prevent a failed caller
    # from stranding a fixture process waiting for a peer that never arrives.
    # A test that gives `open_launcher/5` a curl of its own has it run
    # instead, from $SHEPHERD_TEST_CURL.
    executable(Path.join(shared, "http/curl"), ~S"""
    #!/usr/bin/env bash
    if [[ -n "${SHEPHERD_TEST_CURL:-}" ]]; then eval "$SHEPHERD_TEST_CURL"; exit; fi
    if [[ -n "${SHEPHERD_TEST_ATTACH_FIFO:-}" ]] && mkdir "$SHEPHERD_TEST_ATTACH_FIFO.sent" 2>/dev/null; then
      printf 'attach\n' 1<> "$SHEPHERD_TEST_ATTACH_FIFO"
    fi
    printf 's 000\n'
    exit 7
    """)

    # A ps that fails as Claude Code's sandbox makes it.
    executable(
      Path.join(shared, "deny-ps/ps"),
      "#!/bin/sh\necho 'ps: Operation not permitted' >&2\nexit 1\n"
    )

    for tool <- ~w(ps wc tr tail head) do
      executable(
        Path.join([shared, "logged", tool]),
        ~s(#!/bin/sh\necho #{tool} >> "$CALLS"\nexec #{System.find_executable(tool)} "$@"\n)
      )
    end

    # Every `sleep` takes a second and is logged to $SLEEPS.
    executable(
      Path.join(shared, "slow/sleep"),
      ~s(#!/bin/sh\necho slept >> "$SLEEPS"\nexec /bin/sleep 1\n)
    )

    # The dev launcher's `mix compile` exits $COMPILE_CODE, and each `mix
    # run` the next of $SEQ; its asset build exits $BUILD_CODE.
    executable(Path.join(shared, "dev-stubs/mix"), ~S"""
    #!/usr/bin/env bash
    if [[ "$1" == compile ]]; then exit "$COMPILE_CODE"; fi
    i=$(cat "$I_FILE"); codes=($SEQ)
    echo $((i + 1)) > "$I_FILE"
    exit "${codes[$i]:-76}"
    """)

    executable(Path.join(shared, "dev-stubs/bunx"), ~s(#!/usr/bin/env bash\nexit "$BUILD_CODE"\n))

    # `mix compile` succeeds; each `mix run` records its args and stdin.
    executable(Path.join(shared, "answers-stubs/mix"), ~S"""
    #!/usr/bin/env bash
    if [[ "$1" == compile ]]; then exit 0; fi
    echo "$*" >> "$RUNS_FILE"
    cat >> "$STDIN_FILE"
    exit 76
    """)

    # The stubs of `port_file_between_runs/4`.
    executable(
      Path.join(shared, "between/dev/mix"),
      "#!/usr/bin/env bash\nif [[ \"$1\" != run ]]; then\n#{record_port_file("mix")}\nexit 0\nfi\n" <>
        @between_beam
    )

    for {stubs, name, exec} <- [
          {"dev", "find", ~s(exec /usr/bin/find "$@")},
          {"dev", "bunx", "exit 0"},
          {"prod", "readlink", ~s(exec /usr/bin/readlink "$@")}
        ] do
      executable(
        Path.join([shared, "between", stubs, name]),
        "#!/usr/bin/env bash\n#{record_port_file(name)}\n#{exec}\n"
      )
    end

    File.mkdir_p!(Path.join(shared, "review"))
    dev_root(Path.join(shared, "roots/plain"), nil)
    dev_root(Path.join(shared, "roots/elsewhere"), "/elsewhere")
    dev_root(Path.join(shared, "roots/own"), :root)
  end

  # A path in the tree `build_shared/1` builds.
  defp shared(path), do: Path.join(:persistent_term.get({__MODULE__, :shared}), path)

  # A fresh dir for what a test's run writes, removed when the test exits.
  defp test_dir do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-shep")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp executable(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  # The fake BEAM of `run_shepherd/2`, which exits with each code of $SEQ
  # in turn.
  @scripted_beam ~S"""
  i=$(cat "$I_FILE"); codes=($SEQ)
  echo $((i + 1)) > "$I_FILE"
  if [[ -n "${STDIN_FILE:-}" ]]; then cat >> "$STDIN_FILE"; fi
  echo "${MEERKAT_PREFERRED_PORT:-none} ${*:3}" >> "$PORTS_FILE"
  if [[ -n "${SHEPHERD_TEST_ATTACH_FIFO:-}" ]]; then exec 3<> "$SHEPHERD_TEST_ATTACH_FIFO"; fi
  if [[ -n "${MEERKAT_SERVE_DIR:-}" ]]; then echo "$((i + 1)) $$" > "$MEERKAT_SERVE_DIR/port"; fi
  if [[ -n "${SHEPHERD_TEST_ATTACH_FIFO:-}" ]] && ! read -r -t 10 _ <&3; then exit 2; fi
  exit "${codes[$i]:-76}"
  """

  # Returns the shepherd's exit code, how many times the fake BEAM ran,
  # and, when `input` is given, what the BEAM read on stdin. On each
  # iteration i, the fake BEAM writes `<i+1> <pid>` to
  # `$MEERKAT_SERVE_DIR/port`; with `ports: true`, it also returns the
  # preferred port each run saw (`none` if unset) and its args.
  defp run_shepherd(exit_codes, opts \\ []) do
    dir = test_dir()
    File.write!(Path.join(dir, "i"), "0")
    input = Keyword.get(opts, :input)
    input_file = Path.join(dir, "input")
    if input, do: File.write!(input_file, input)

    env =
      fake_release(@scripted_beam) ++
        [
          {"SEQ", Enum.join(exit_codes, " ")},
          {"PORTS_FILE",
           if(Keyword.get(opts, :ports), do: Path.join(dir, "ports"), else: "/dev/null")},
          {"STDIN_FILE", if(input, do: Path.join(dir, "stdin"))},
          {"INPUT_FILE", if(input, do: input_file, else: "/dev/null")}
        ]

    args = Keyword.get(opts, :args, ["--commit-msg", "/tmp/msg", "--no-open"])
    code = run_launcher(@shepherd, args, env ++ Keyword.get(opts, :env, []), dir)
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
  defp dev_launcher_between_runs(args \\ ["--commit-msg", "/tmp/msg", "--no-open"], env \\ []) do
    port_file_between_runs(Path.join(File.cwd!(), "bin/meerkat-beam"), "dev", env, args)
  end

  defp prod_shepherd_between_runs(env \\ []) do
    port_file_between_runs(@shepherd, "prod", fake_release(@between_beam) ++ env)
  end

  # Runs `launcher` with the stubs in the shared `between/<stubs>` dir
  # shadowing the commands it runs between BEAMs: each records what
  # `record_port_file/1` does, then runs its real command, or exits 0
  # without one; the dev stubs' `mix run` is the BEAM. Returns what was
  # recorded, in order and without repeats.
  defp port_file_between_runs(
         launcher,
         stubs,
         env,
         args \\ ["--commit-msg", "/tmp/msg", "--no-open"]
       ) do
    dir = test_dir()
    File.write!(Path.join(dir, "i"), "0")
    File.write!(Path.join(dir, "seen"), "")

    env =
      env ++
        [
          {"PATH", shared(Path.join("between", stubs)) <> ":" <> System.fetch_env!("PATH")},
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

  # Runs the dev launcher's served half (MEERKAT_SERVE_DIR set, so no
  # caller), in a checkout that has no build unless `built` is given,
  # from a `review` dir, with `mix` and `bunx` replaced by stubs: `mix
  # compile` exits `compile_code`, the asset build exits `build_code`,
  # and each `mix run` exits the next of `exit_codes`, counting runs in
  # the temp dir's `i`. With `built`, the checkout has a source, a build
  # manifest newer than it, and a stamp naming `built` as the checkout
  # that compiled the build (`:root` names the checkout itself). Returns
  # the launcher's port, the temp dir and the checkout.
  defp open_dev_shepherd(opts) do
    dir = test_dir()
    File.mkdir_p!(Path.join(dir, "serve"))
    File.write!(Path.join(dir, "i"), "0")
    built = Keyword.get(opts, :built)
    compile_code = Keyword.get(opts, :compile_code, 0)

    # A compile that succeeds stamps a build, so a checkout whose build
    # it would stamp is the test's own; the shared ones are only read.
    root =
      cond do
        built == nil -> shared("roots/plain")
        built == :root -> shared("roots/own")
        compile_code == 0 -> dev_root(Path.join(dir, "root"), built)
        true -> shared("roots/elsewhere")
      end

    port =
      open_launcher(
        Path.join([root, "bin", "meerkat-beam"]),
        ["--commit-msg", shared("review/COMMIT_MSG"), "--no-open"],
        dir,
        [
          {"PATH", shared("dev-stubs") <> ":" <> System.fetch_env!("PATH")},
          {"MIX_ENV", "dev"},
          {"MEERKAT_SERVE_DIR", Path.join(dir, "serve")},
          {"MEERKAT_SERVE_TOKEN", "t"},
          {"SEQ", Enum.join(Keyword.get(opts, :exit_codes, []), " ")},
          {"COMPILE_CODE", to_string(compile_code)},
          {"BUILD_CODE", to_string(Keyword.get(opts, :build_code, 0))},
          {"INPUT_FILE", "/dev/null"}
        ],
        cd: shared("review")
      )

    {port, dir, root}
  end

  # A copy of the dev launcher in a checkout of its own at `root`, so a
  # stub compile stamps no real build. With `built`, the checkout has a
  # build that `built` compiled, as `open_dev_shepherd/1` describes.
  defp dev_root(root, built) do
    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir_p!(Path.join(root, "assets"))

    for name <- ["meerkat-beam", "meerkat-attach"],
        do: File.cp!(Path.join([File.cwd!(), "bin", name]), Path.join([root, "bin", name]))

    File.chmod!(Path.join([root, "bin", "meerkat-beam"]), 0o755)

    if built do
      source = Path.join(root, "lib/meerkat.ex")
      manifest = Path.join(root, "_build/dev/lib/meerkat/.mix/compile.elixir")
      File.mkdir_p!(Path.dirname(source))
      File.mkdir_p!(Path.dirname(manifest))
      File.write!(source, "")
      File.touch!(source, {{2020, 1, 1}, {0, 0, 0}})
      File.write!(manifest, "")
      stamp = if built == :root, do: root, else: built
      File.write!(Path.join(root, "_build/dev/.meerkat-root"), stamp <> "\n")
    end

    root
  end

  # The env that points a launcher at the shared release, whose BEAM runs
  # `body`.
  defp fake_release(body),
    do: [{"MEERKAT_CURRENT_LINK", shared("current")}, {"FAKE_BEAM", body}]

  # Starts a caller whose first BEAM never binds and sleeps a minute;
  # every later BEAM exits 7 once the `go` file exists. With `deny_ps`,
  # the launchers' ps fails as in Claude Code's sandbox.
  defp open_killable_review(deny_ps \\ false) do
    dir = test_dir()
    runs = Path.join(dir, "runs")
    File.write!(Path.join(dir, "i"), "0")
    go = Path.join(dir, "go")

    env =
      fake_release(~S"""
      i=$(cat "$I_FILE"); echo $((i + 1)) > "$I_FILE"
      touch "$(dirname "$I_FILE")/beam-$((i + 1))"
      if [[ "$i" == 0 ]]; then exec sleep 60; fi
      while [[ ! -f "$GO_FILE" ]]; do sleep 0.05; done
      exit 7
      """) ++ [{"GO_FILE", go}, {"INPUT_FILE", "/dev/null"}]

    env = if deny_ps, do: [{"PATH", deny_ps_path()} | env], else: env

    first = open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, env)
    {:os_pid, first_pid} = Port.info(first, :os_pid)
    backend = await_backend_pid(runs)
    # Once its BEAM runs, the shepherd turns a SIGTERM into exit 143.
    assert await_file(Path.join(dir, "beam-1")) == ""

    %{
      dir: dir,
      runs: runs,
      go: go,
      env: env,
      first: first,
      first_pid: to_string(first_pid),
      backend: backend
    }
  end

  # SIGTERMs the review's backend and, once it has recorded its exit
  # code, reruns the review; returns the rerun once it has a backend.
  defp kill_backend_and_rerun(review) do
    System.cmd("kill", ["-TERM", review.backend])
    await_match(Path.join([review.runs, "*", "exit"]))

    second =
      open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], review.dir, review.env)

    await_backend_pid(review.runs, [review.backend])
    second
  end

  # The pid of a detached shepherd not in `known`, once a caller has
  # started it.
  defp await_backend_pid(runs, known \\ []) do
    eventually(
      fn ->
        Path.join([runs, "*", "pid"])
        |> Path.wildcard()
        |> Enum.flat_map(&read_pid/1)
        |> Enum.find(&(&1 not in known))
      end,
      timeout: @timeout_ms
    ) || flunk("the caller started no backend in #{runs}")
  end

  # A caller may remove a run dir between the listing and the read.
  defp read_pid(path) do
    case File.read(path) do
      {:ok, pid} -> [String.trim(pid)]
      {:error, _} -> []
    end
  end

  # The BEAM pid from the port file the backend's BEAM records.
  defp await_beam_pid(runs) do
    eventually(
      fn ->
        case Path.wildcard(Path.join([runs, "*", "port"])) do
          [port_file | _] -> port_file |> File.read() |> beam_pid()
          [] -> nil
        end
      end,
      timeout: @timeout_ms
    ) || flunk("no BEAM recorded its port in #{runs}")
  end

  # Read between the BEAM's truncate and write, the port file is empty; a
  # caller may also remove its run dir between the listing and the read.
  defp beam_pid({:ok, contents}), do: contents |> String.split() |> List.last()
  defp beam_pid({:error, _}), do: nil

  # Whether process `pid` exits within @timeout_ms. Each probe starts a
  # `ps`, so probes come 50 ms apart.
  defp await_gone(pid) do
    eventually(
      fn -> match?({_, 1}, System.cmd("ps", ["-p", pid], stderr_to_stdout: true)) end,
      timeout: @timeout_ms,
      interval: 50
    )
  end

  # Runs a launcher as a caller with `env`, which adds to or (with nil)
  # removes from the variables every run shares, and returns its exit code.
  defp run_launcher(launcher, args, env, dir) do
    launcher |> open_launcher(args, dir, env) |> await_exit(dir)
  end

  # Starts a launcher as `run_launcher/4` does and returns its port;
  # `opts[:cd]` sets its working directory, and `opts[:curl]` replaces the
  # refusing curl below with a script of its own.
  defp open_launcher(launcher, args, dir, env, opts \\ []) do
    base = [
      {"MEERKAT_PORT", "44444"},
      # A caller running inside a BEAM inherits its preference; the
      # launcher must not pass it on to its own first BEAM.
      {"MEERKAT_PREFERRED_PORT", "12345"},
      {"MEERKAT_RUNS_DIR", Path.join(dir, "runs")},
      {"I_FILE", Path.join(dir, "i")},
      {"SECRET_KEY_BASE", nil},
      # A shepherd run by a caller has this set; the caller itself does not.
      {"MEERKAT_SERVE_DIR", nil}
    ]

    # Piped when there is input, as a caller piping answers in does;
    # /dev/null otherwise. With :own_group, the caller leads its own process
    # group, as under an app that signals its whole tree, and the port runs
    # the bash that started it, which records the caller's pid in
    # $CALLER_PID_FILE. Only the caller's own stderr reaches the port: that
    # bash reports its job's death too.
    {shell, script} =
      if Keyword.get(opts, :own_group) do
        {"/bin/bash",
         ~S"""
         exec 3>&2 2>/dev/null
         set -m
         "$0" "$@" </dev/null 2>&3 3>&- &
         echo "$!" >"$CALLER_PID_FILE.tmp" && mv "$CALLER_PID_FILE.tmp" "$CALLER_PID_FILE"
         wait "$!"
         """}
      else
        {"/bin/sh",
         ~S"""
         if [ "$INPUT_FILE" = /dev/null ]; then exec "$0" "$@" </dev/null; fi
         cat "$INPUT_FILE" | "$0" "$@"
         """}
      end

    env =
      base
      |> Map.new()
      |> Map.merge(Map.new(env))
      |> Map.put("SHEPHERD_TEST_CURL", Keyword.get(opts, :curl))

    env =
      Map.put(
        env,
        "PATH",
        shared("http") <> ":" <> Map.get(env, "PATH", System.fetch_env!("PATH"))
      )

    Port.open(
      {:spawn_executable, shell},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", script, launcher | args],
        env: Enum.map(env, fn {k, v} -> {~c"#{k}", if(v, do: ~c"#{v}", else: false)} end)
      ] ++ Keyword.take(opts, [:cd])
    )
  end

  # Waits for the launcher to print `text`.
  defp await_output(port, dir, text, seen \\ "") do
    receive do
      {^port, {:data, data}} ->
        if String.contains?(seen <> data, text),
          do: :ok,
          else: await_output(port, dir, text, seen <> data)

      {^port, {:exit_status, code}} ->
        flunk("the launcher exited #{code} before printing #{inspect(text)}:\n#{seen}")
    after
      @timeout_ms ->
        kill_launcher(port, dir)
        flunk("the launcher did not print #{inspect(text)} within #{@timeout_ms} ms:\n#{seen}")
    end
  end

  defp await_exit(port, dir), do: port |> await_result(dir) |> elem(0)

  # The launcher's exit code and everything it printed.
  defp await_result(port, dir, seen \\ "") do
    receive do
      {^port, {:data, data}} -> await_result(port, dir, seen <> data)
      {^port, {:exit_status, code}} -> {code, seen}
    after
      @timeout_ms ->
        kill_launcher(port, dir)
        flunk("meerkat-shepherd did not exit within #{@timeout_ms} ms:\n#{seen}")
    end
  end

  # Kills the caller and the detached shepherd it started, which has its
  # own session and would outlive the caller.
  defp kill_launcher(port, dir) do
    {:os_pid, pid} = Port.info(port, :os_pid)
    # Kill the caller first so it cannot start another detached shepherd.
    caller = to_string(pid)
    System.cmd("pkill", ["-9", "-P", caller])
    System.cmd("kill", ["-9", caller])

    # A shepherd may not have written its pid file yet. Missed, it outlives
    # the test; once its stub directory is deleted, it runs the real `mix`
    # and starts a BEAM that never exits. Not every run dir gets a pid, so
    # each wait gets 10 s, not @timeout_ms: after a wait that timed out,
    # @timeout_ms of the 180 s test timeout is already spent.
    detached =
      for run <- Path.wildcard(Path.join([dir, "runs", "*"])),
          backend = await_file(Path.join(run, "pid"), 10_000),
          do: backend

    if detached != [] do
      System.cmd("pkill", ["-9", "-P", Enum.join(detached, ",")])
      System.cmd("kill", ["-9" | detached])
    end
  end

  # The trimmed contents of `path` once it exists, or nil after @timeout_ms.
  defp await_file(path, timeout_ms \\ @timeout_ms) do
    eventually(
      fn ->
        case File.read(path) do
          {:ok, contents} -> String.trim(contents)
          {:error, _} -> nil
        end
      end,
      timeout: timeout_ms
    )
  end

  # The key naming the run dir of a review run with MEERKAT_PWD=`dir` and
  # the arguments every test here passes.
  defp run_key(dir) do
    :crypto.hash(:sha256, "#{dir}:--commit-msg /tmp/msg --no-open")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # What a reap that could not delete a run leaves: the review's key names
  # an empty run dir whose backend never writes its pid. Returns the runs dir.
  defp emptied_run(dir) do
    runs = Path.join(dir, "runs")
    emptied = run_key(dir) <> ".emptied"
    File.mkdir_p!(Path.join(runs, emptied))
    File.ln_s!(emptied, Path.join(runs, run_key(dir)))
    runs
  end

  # Runs `script` in bash with bin/meerkat-attach sourced, so it can call the
  # launcher's functions, and `arg` as "$2". Returns System.cmd's result.
  defp attach_shell(script, arg) do
    System.cmd("bash", [
      "-c",
      ~S(source "$1"; ) <> script,
      "attach",
      Path.expand("bin/meerkat-attach"),
      arg
    ])
  end

  # Whether `path` holds `text` within @timeout_ms.
  defp await_content(path, text) do
    eventually(fn -> File.read(path) == {:ok, text <> "\n"} end, timeout: @timeout_ms)
  end

  # A PATH whose ps fails as Claude Code's sandbox makes it.
  defp deny_ps_path, do: shared("deny-ps") <> ":" <> System.get_env("PATH")

  # Waits up to @timeout_ms for `pattern` to match a path.
  defp await_match(pattern) do
    eventually(fn -> Path.wildcard(pattern) != [] end, timeout: @timeout_ms) ||
      flunk("nothing matched #{pattern}")
  end
end
