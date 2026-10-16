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

  test "propagates a SIGTERM halt (exit 143) straight through" do
    assert run_shepherd([143]) == %{code: 143, iterations: 1}
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

  test "a fake BEAM's port announcement cannot reach an unrelated HTTP client" do
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep-http")
    on_exit(fn -> File.rm_rf!(dir) end)
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

    assert run_shepherd([0],
             env: [
               {"PATH", dir <> ":" <> System.fetch_env!("PATH")},
               {"SHEPHERD_TEST_ATTACH_FIFO", fifo}
             ]
           ) == %{code: 0, iterations: 1}

    assert File.dir?(fifo <> ".sent")
    refute File.exists?(marker)
  end

  for flag <- ["--answers", "--answers=true"] do
    test "the dev launcher runs #{flag} once in the foreground with the caller's stdin" do
      input = ~s({"answers":[{"location":"global","question":"q","answer":"a"}]}\n)
      dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
      on_exit(fn -> File.rm_rf!(dir) end)
      stubs = Path.join(dir, "stubs")
      File.mkdir_p!(stubs)

      # `mix compile` succeeds; each `mix run` records its args and stdin.
      File.write!(Path.join(stubs, "mix"), ~S"""
      #!/usr/bin/env bash
      if [[ "$1" == compile ]]; then exit 0; fi
      echo "$*" >> "$RUNS_FILE"
      cat >> "$STDIN_FILE"
      """)

      File.chmod!(Path.join(stubs, "mix"), 0o755)
      File.write!(Path.join(dir, "input"), input)

      env = [
        {"PATH", stubs <> ":" <> System.fetch_env!("PATH")},
        {"RUNS_FILE", Path.join(dir, "runs-seen")},
        {"STDIN_FILE", Path.join(dir, "stdin")},
        {"INPUT_FILE", Path.join(dir, "input")}
      ]

      # A copy in a checkout of its own, so the stub compile stamps no
      # real build.
      launcher = Path.join([dir, "root", "bin", "meerkat-beam"])
      File.mkdir_p!(Path.dirname(launcher))
      File.cp!(Path.join(File.cwd!(), "bin/meerkat-beam"), launcher)
      File.chmod!(launcher, 0o755)

      assert run_launcher(launcher, [unquote(flag)], env, dir) == 0

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
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
    on_exit(fn -> File.rm_rf!(dir) end)
    rel = Path.join(dir, "rel")
    fake_bin = Path.join(dir, "fakebin")
    File.mkdir_p!(Path.join(rel, "bin"))
    File.mkdir_p!(fake_bin)
    File.ln_s!(rel, Path.join(dir, "current"))

    File.write!(
      Path.join(fake_bin, "ps"),
      "#!/bin/sh\necho 'ps: Operation not permitted' >&2\nexit 1\n"
    )

    # Decides after the caller's first checks, without binding a port.
    File.write!(Path.join([rel, "bin", "meerkat"]), "#!/usr/bin/env bash\nsleep 1.5\nexit 0\n")

    for file <- [Path.join(fake_bin, "ps"), Path.join([rel, "bin", "meerkat"])],
        do: File.chmod!(file, 0o755)

    port =
      open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, [
        {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
        {"INPUT_FILE", "/dev/null"},
        {"PATH", fake_bin <> ":" <> System.get_env("PATH")}
      ])

    assert await_exit(port, dir) == 0
  end

  # A caller exits once a process above it has gone, and must not take a
  # live one it may not signal, such as root-owned launchd, for gone.
  test "a caller's liveness check tells a gone process from a live one, signalable or not" do
    script = ~S"""
    source "$1"
    sleep 0 &
    gone=$!
    wait "$gone"
    for pid in "$gone" $$ 1; do
      if _ma_alive "$pid"; then echo live; else echo gone; fi
    done
    """

    assert {"gone\nlive\nlive\n", 0} =
             System.cmd("bash", ["-c", script, "alive", Path.expand("bin/meerkat-attach")])
  end

  # A caller relays its backend's log as it grows: from the start for a run
  # it started, even one with no log yet, and from the end on reattach.
  test "a caller relays each part of its backend's log once" do
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
    on_exit(fn -> File.rm_rf!(dir) end)

    script = ~S"""
    source "$1"
    exec 2>&1
    _MA_LOG_FD=""
    _MA_DIR="$2/started"
    mkdir "$_MA_DIR"
    _ma_open_log || echo "no log yet"
    _ma_relay_log
    printf 'a\npart' >"$_MA_DIR/log"
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

    assert {"no log yet\na\npartial\nb\n", 0} =
             System.cmd("bash", ["-c", script, "relay", Path.expand("bin/meerkat-attach"), dir])
  end

  # A waiting caller checks every second that the process that ran it
  # lives, and relays its backend's log every 0.2 s. Forking ps for the
  # one, and wc, tail and head for the other, cost about 0.1 CPU-s a second.
  test "a caller waiting on a decision runs no process while it relays the backend's log" do
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
    on_exit(fn -> File.rm_rf!(dir) end)
    stubs = Path.join(dir, "stubs")
    File.mkdir_p!(stubs)

    for tool <- ~w(ps wc tr tail head) do
      real = System.find_executable(tool)
      stub = Path.join(stubs, tool)
      File.write!(stub, ~s(#!/bin/sh\necho #{tool} >> "$CALLS"\nexec #{real} "$@"\n))
      File.chmod!(stub, 0o755)
    end

    fake_release(dir, ~S"""
    echo "1 $$" > "$MEERKAT_SERVE_DIR/port"
    sleep 0.5
    printf 'warn' >&2
    sleep 0.5
    printf 'ing\n' >&2
    for _ in {1..600}; do
      [[ -f "$DELIVERED" ]] && exit 0
      sleep 0.1
    done
    exit 1
    """)

    # The attach stream sends only heartbeats for 3 s, then an approval.
    curl = ~S"""
    #!/usr/bin/env bash
    case "$*" in
      *attach/delivered*) touch "$DELIVERED"; exit 0 ;;
    esac
    echo start >> "$CALLS"
    for _ in 1 2 3 4 5 6; do
      printf 'k\n'
      sleep 0.5
    done
    echo end >> "$CALLS"
    printf 'x 0\ns 200\n'
    """

    calls = Path.join(dir, "calls")

    port =
      open_launcher(
        @shepherd,
        ["--commit-msg", "/tmp/msg", "--no-open"],
        dir,
        [
          {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
          {"INPUT_FILE", "/dev/null"},
          {"CALLS", calls},
          {"DELIVERED", Path.join(dir, "delivered")},
          {"PATH", stubs <> ":" <> System.get_env("PATH")}
        ],
        curl: curl
      )

    assert {0, output} = await_result(port, dir)
    assert output =~ "warning\n"

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
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "i"), "0")

    # The first BEAM deletes both files and asks for a restart; the second
    # approves only if both are back as they were.
    fake_release(dir, ~S"""
    i=$(cat "$I_FILE"); echo $((i + 1)) > "$I_FILE"
    if [[ "$i" == 0 ]]; then
      cp "$MEERKAT_SERVE_DIR/token" "$TOKEN_SEEN"
      rm "$MEERKAT_SERVE_DIR/token" "$MEERKAT_SERVE_DIR/pid"
      exit 75
    fi
    cmp -s "$TOKEN_SEEN" "$MEERKAT_SERVE_DIR/token" || exit 1
    [[ "$(cat "$MEERKAT_SERVE_DIR/pid")" == "$PPID" ]] || exit 1
    exit 0
    """)

    env = [
      {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
      {"TOKEN_SEEN", Path.join(dir, "token-seen")},
      {"INPUT_FILE", "/dev/null"}
    ]

    assert run_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], env, dir) == 0
  end

  test "a review keeps its run dir and browser-open marker out of $TMPDIR" do
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
    on_exit(fn -> File.rm_rf!(dir) end)

    fake_release(dir, ~S"""
    echo "$MEERKAT_SERVE_DIR $MEERKAT_OPEN_MARKER" > "$SEEN_FILE"
    """)

    env = [
      {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
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

  for {signal, number} <- [{"TERM", 15}, {"INT", 2}, {"HUP", 1}] do
    test "a caller stopped by SIG#{signal} says the review is still open and dies of the signal" do
      dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
      on_exit(fn -> File.rm_rf!(dir) end)
      rel = Path.join(dir, "rel")
      File.mkdir_p!(Path.join(rel, "bin"))
      File.ln_s!(rel, Path.join(dir, "current"))
      # A BEAM that never binds, so the review has no URL yet.
      File.write!(Path.join([rel, "bin", "meerkat"]), "#!/usr/bin/env bash\nexec sleep 60\n")
      File.chmod!(Path.join([rel, "bin", "meerkat"]), 0o755)

      port =
        open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, [
          {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
          {"INPUT_FILE", "/dev/null"}
        ])

      runs = Path.join(dir, "runs")
      backend = await_backend_pid(runs)

      # The shepherd's EXIT trap writes `exit` into its run dir after the
      # TERM; deleting the dir before then races that write.
      on_exit(fn ->
        System.cmd("kill", ["-TERM", backend], stderr_to_stdout: true)
        for run <- Path.wildcard(Path.join(runs, "*")), do: await_file(Path.join(run, "exit"))
      end)

      {:os_pid, caller} = Port.info(port, :os_pid)
      System.cmd("kill", ["-#{unquote(signal)}", to_string(caller)])

      assert {code, output} = await_result(port, dir)
      assert code == 128 + unquote(number)

      assert output =~
               "meerkat: stopped waiting (SIG#{unquote(signal)}) before the review completed. " <>
                 "The review is still open; run the same command again to wait for its outcome.\n"

      assert {_, 0} = System.cmd("kill", ["-0", backend], stderr_to_stdout: true)
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

      await_backend_pid(review.runs, 100, [review.backend])
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
      await_backend_pid(review.runs, 100, [review.backend])
      File.write!(review.go, "")

      assert await_exit(second, review.dir) == 7
      assert File.ls!(review.runs) == []
    end
  end

  describe "an older meerkat's run dir at the review's key" do
    test "is removed once finished, and the caller starts a new run" do
      dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
      on_exit(fn -> File.rm_rf!(dir) end)
      fake_release(dir, "exit 0\n")
      old = Path.join([dir, "runs", run_key(dir)])
      File.mkdir_p!(old)
      File.write!(Path.join(old, "exit"), "5\n")

      env = [
        {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
        {"MEERKAT_PWD", dir},
        {"INPUT_FILE", "/dev/null"}
      ]

      assert run_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], env, dir) == 0
      assert File.ls!(Path.join(dir, "runs")) == []
    end

    test "is left in place when a caller drops a run the key no longer names" do
      dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
      on_exit(fn -> File.rm_rf!(dir) end)
      old = Path.join(dir, "key")
      File.mkdir_p!(old)

      {_, 0} =
        System.cmd("bash", [
          "-c",
          ~S(source "$1"; _MA_LINK="$2"; _MA_RUN=r; _ma_retire "$2.finished"),
          "retire",
          Path.expand("bin/meerkat-attach"),
          old
        ])

      refute File.exists?(old <> ".retiring.r")
      assert File.dir?(old) and not match?({:ok, _}, File.read_link(old))
    end
  end

  describe "once the review is removed" do
    test "a caller whose runs dir is deleted exits 2 instead of retrying" do
      dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
      on_exit(fn -> File.rm_rf!(dir) end)
      runs = Path.join(dir, "runs")
      rel = Path.join(dir, "rel")
      File.mkdir_p!(Path.join(rel, "bin"))
      File.ln_s!(rel, Path.join(dir, "current"))
      # A BEAM that never binds, so the caller keeps polling its run dir.
      # It says when it starts: until then the shepherd writes to the run
      # dir, which would race deleting it.
      File.write!(
        Path.join([rel, "bin", "meerkat"]),
        "#!/usr/bin/env bash\ntouch \"$BEAM_STARTED\"\nexec sleep 60\n"
      )

      File.chmod!(Path.join([rel, "bin", "meerkat"]), 0o755)
      started = Path.join(dir, "beam-started")

      port =
        open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, [
          {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
          {"BEAM_STARTED", started},
          {"INPUT_FILE", "/dev/null"}
        ])

      backend = await_backend_pid(runs)
      on_exit(fn -> System.cmd("kill", ["-TERM", backend], stderr_to_stdout: true) end)
      assert await_file(started) == ""

      File.rm_rf!(runs)

      assert await_exit(port, dir) == 2
    end

    test "a caller whose backend dies exits 2, rejecting the commit, and stops the BEAM it left" do
      dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
      on_exit(fn -> File.rm_rf!(dir) end)
      runs = Path.join(dir, "runs")
      rel = Path.join(dir, "rel")
      File.mkdir_p!(Path.join(rel, "bin"))
      File.ln_s!(rel, Path.join(dir, "current"))

      # A BEAM that records its port, as a serving one does, on a port
      # nothing listens on, and runs until killed or for a minute. It
      # loops rather than exec'ing sleep: the caller kills only a process
      # whose command line names meerkat.
      File.write!(Path.join([rel, "bin", "meerkat"]), ~S"""
      #!/usr/bin/env bash
      echo "1 $$" > "$MEERKAT_SERVE_DIR/port"
      for _ in {1..60}; do sleep 1; done
      """)

      File.chmod!(Path.join([rel, "bin", "meerkat"]), 0o755)

      port =
        open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, [
          {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
          {"INPUT_FILE", "/dev/null"}
        ])

      backend = await_backend_pid(runs)
      beam = await_beam_pid(runs)

      on_exit(fn -> System.cmd("kill", ["-KILL", beam], stderr_to_stdout: true) end)

      System.cmd("kill", ["-KILL", backend])

      assert {2, output} = await_result(port, dir)

      assert output =~
               "meerkat: the review backend died without a decision — defaulting to REJECT (commit aborted)."

      assert await_gone(beam), "the BEAM #{beam} its backend left is still running"
    end

    test "a caller that cannot create its run dir exits 2 instead of retrying" do
      dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
      runs = Path.join(dir, "runs")
      File.mkdir_p!(runs)
      File.chmod!(runs, 0o555)

      on_exit(fn ->
        File.chmod!(runs, 0o755)
        File.rm_rf!(dir)
      end)

      port =
        open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, [
          {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
          {"INPUT_FILE", "/dev/null"}
        ])

      assert await_exit(port, dir) == 2
    end

    test "a caller whose runs dir cannot be changed exits 2 instead of spinning" do
      dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
      runs = Path.join(dir, "runs")
      File.mkdir_p!(runs)
      # Names a finished run that is gone.
      File.ln_s!(run_key(dir) <> ".gone", Path.join(runs, run_key(dir)))
      File.chmod!(runs, 0o555)

      on_exit(fn ->
        File.chmod!(runs, 0o755)
        File.rm_rf!(dir)
      end)

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
      dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
      runs = Path.join(dir, "runs")
      # A finished run whose caller is gone; its own dir stays writable, so
      # removing it empties it but cannot delete it.
      finished = Path.join(runs, run_key(dir) <> ".finished")
      File.mkdir_p!(finished)

      for {name, body} <- [{"exit", "143"}, {"caller", "999999"}, {"token", "t"}],
          do: File.write!(Path.join(finished, name), body <> "\n")

      File.chmod!(runs, 0o555)

      on_exit(fn ->
        File.chmod!(runs, 0o755)
        File.rm_rf!(dir)
      end)

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
      dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
      runs = Path.join(dir, "runs")
      # What a reap that could not delete a run leaves: the key names an
      # empty run dir whose backend never writes its pid.
      emptied = run_key(dir) <> ".emptied"
      File.mkdir_p!(Path.join(runs, emptied))
      File.ln_s!(emptied, Path.join(runs, run_key(dir)))
      File.chmod!(runs, 0o555)

      on_exit(fn ->
        File.chmod!(runs, 0o755)
        File.rm_rf!(dir)
      end)

      port =
        open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, [
          {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
          {"MEERKAT_PWD", dir},
          {"INPUT_FILE", "/dev/null"}
        ])

      # The caller waits 10 s for the backend's pid before burying it.
      assert {2, output} = await_result(port, dir, "", 20_000)

      assert output =~
               "meerkat: could not update #{runs} — defaulting to REJECT (commit aborted).\n"
    end

    test "the dev shepherd propagates a crash (exit 2) instead of waiting for a source change" do
      {port, dir} = open_dev_shepherd(exit_codes: [2, 0])

      assert await_exit(port, dir) == 2
      assert File.read!(Path.join(dir, "i")) |> String.trim() == "1"
    end

    test "the dev shepherd compiles a build that looks fresh but was compiled in another checkout" do
      {port, dir} = open_dev_shepherd(compile_code: 1, built: "/elsewhere")

      await_output(port, dir, "waiting for source change")
      kill_launcher(port, dir)
      assert File.read!(Path.join(dir, "root/_build/dev/.meerkat-root")) == "/elsewhere\n"
    end

    test "a successful compile stamps the build with its checkout" do
      {port, dir} = open_dev_shepherd(built: "/elsewhere", exit_codes: [0])

      assert await_exit(port, dir) == 0

      assert File.read!(Path.join(dir, "root/_build/dev/.meerkat-root")) ==
               Path.join(dir, "root") <> "\n"
    end

    test "the dev shepherd skips `mix compile` for a fresh build compiled in its own checkout" do
      {port, dir} = open_dev_shepherd(compile_code: 1, built: :root, exit_codes: [0])

      assert await_exit(port, dir) == 0
    end

    for deleted <- ["review", "root"] do
      test "the dev shepherd exits 2 when its #{deleted} dir is deleted while it waits for a source change" do
        {port, dir} = open_dev_shepherd(compile_code: 1)
        await_output(port, dir, "waiting for source change")

        File.rm_rf!(Path.join(dir, unquote(deleted)))

        assert await_exit(port, dir) == 2
      end
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
    if [[ -n "${SHEPHERD_TEST_ATTACH_FIFO:-}" ]]; then exec 3<> "$SHEPHERD_TEST_ATTACH_FIFO"; fi
    if [[ -n "${MEERKAT_SERVE_DIR:-}" ]]; then echo "$((i + 1)) $$" > "$MEERKAT_SERVE_DIR/port"; fi
    if [[ -n "${SHEPHERD_TEST_ATTACH_FIFO:-}" ]] && ! read -r -t 10 _ <&3; then exit 2; fi
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
    port_file_between_runs(
      Path.join(File.cwd!(), "bin/meerkat-beam"),
      "stubs/mix",
      "if [[ \"$1\" != run ]]; then\n#{record_port_file("mix")}\nexit 0\nfi",
      [{"find", "/usr/bin/find"}, {"bunx", nil}],
      fn _dir -> env end,
      args
    )
  end

  defp prod_shepherd_between_runs(env \\ []) do
    port_file_between_runs(
      @shepherd,
      "rel/bin/meerkat",
      "",
      [{"readlink", "/usr/bin/readlink"}],
      fn dir ->
        File.ln_s!(Path.join(dir, "rel"), Path.join(dir, "current"))
        [{"MEERKAT_CURRENT_LINK", Path.join(dir, "current")} | env]
      end
    )
  end

  # Runs `launcher` with a fake BEAM at `beam_path` under a temp dir. The
  # BEAM records the preferred port it saw as `beam: <port>` (`beam: none`
  # if unset) and its SECRET_KEY_BASE as `secret: <value>`, writes its
  # port file and exits 75, then 0. `stubs` shadow
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
    echo "secret: ${SECRET_KEY_BASE:-none}" >> "$SEEN_FILE"
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

  # Runs the dev launcher's served half (MEERKAT_SERVE_DIR set, so no
  # caller), copied into a checkout at `root` that has no build unless
  # `built` is given, from a fresh `review` dir, with `mix` and `bunx`
  # replaced by stubs: `mix compile` exits `compile_code`, and each `mix
  # run` exits the next of `exit_codes`, counting runs in the temp dir's
  # `i`. With `built`, `root` has a source, a build manifest newer than
  # it, and a stamp naming `built` as the checkout that compiled the build
  # (`:root` names `root` itself).
  defp open_dev_shepherd(opts) do
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
    on_exit(fn -> File.rm_rf!(dir) end)
    stubs = Path.join(dir, "stubs")

    Enum.each(
      ["review", "serve", "stubs", "root/bin", "root/assets"],
      &File.mkdir_p!(Path.join(dir, &1))
    )

    if built = Keyword.get(opts, :built) do
      source = Path.join(dir, "root/lib/meerkat.ex")
      manifest = Path.join(dir, "root/_build/dev/lib/meerkat/.mix/compile.elixir")
      File.mkdir_p!(Path.dirname(source))
      File.mkdir_p!(Path.dirname(manifest))
      File.write!(source, "")
      File.touch!(source, {{2020, 1, 1}, {0, 0, 0}})
      File.write!(manifest, "")
      root = if built == :root, do: Path.join(dir, "root"), else: built
      File.write!(Path.join(dir, "root/_build/dev/.meerkat-root"), root <> "\n")
    end

    launcher = Path.join([dir, "root", "bin", "meerkat-beam"])
    File.cp!(Path.join(File.cwd!(), "bin/meerkat-beam"), launcher)

    File.cp!(
      Path.join(File.cwd!(), "bin/meerkat-attach"),
      Path.join([dir, "root", "bin", "meerkat-attach"])
    )

    File.chmod!(launcher, 0o755)
    File.write!(Path.join(dir, "seq"), Enum.join(Keyword.get(opts, :exit_codes, []), " "))
    File.write!(Path.join(dir, "i"), "0")

    File.write!(Path.join(stubs, "mix"), """
    #!/usr/bin/env bash
    if [[ "$1" == compile ]]; then exit #{Keyword.get(opts, :compile_code, 0)}; fi
    i=$(cat "$I_FILE"); codes=($(cat "$SEQ_FILE"))
    echo $((i + 1)) > "$I_FILE"
    exit "${codes[$i]:-0}"
    """)

    File.write!(Path.join(stubs, "bunx"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(stubs, "mix"), 0o755)
    File.chmod!(Path.join(stubs, "bunx"), 0o755)

    port =
      open_launcher(
        launcher,
        ["--commit-msg", Path.join([dir, "review", "COMMIT_MSG"]), "--no-open"],
        dir,
        [
          {"PATH", stubs <> ":" <> System.fetch_env!("PATH")},
          {"MIX_ENV", "dev"},
          {"MEERKAT_SERVE_DIR", Path.join(dir, "serve")},
          {"MEERKAT_SERVE_TOKEN", "t"},
          {"SEQ_FILE", Path.join(dir, "seq")},
          {"INPUT_FILE", "/dev/null"}
        ],
        cd: Path.join(dir, "review")
      )

    {port, dir}
  end

  # Points `dir`'s `current` at a release whose BEAM runs `body`.
  defp fake_release(dir, body) do
    beam = Path.join([dir, "rel", "bin", "meerkat"])
    File.mkdir_p!(Path.dirname(beam))
    File.ln_s!(Path.join(dir, "rel"), Path.join(dir, "current"))
    File.write!(beam, "#!/usr/bin/env bash\n" <> body)
    File.chmod!(beam, 0o755)
  end

  # Starts a caller whose first BEAM never binds and sleeps a minute;
  # every later BEAM exits 7 once the `go` file exists. With `deny_ps`,
  # the launchers' ps fails as in Claude Code's sandbox.
  defp open_killable_review(deny_ps \\ false) do
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-shep")
    on_exit(fn -> File.rm_rf!(dir) end)
    runs = Path.join(dir, "runs")
    rel = Path.join(dir, "rel")
    File.mkdir_p!(Path.join(rel, "bin"))
    File.ln_s!(rel, Path.join(dir, "current"))
    File.write!(Path.join(dir, "i"), "0")
    go = Path.join(dir, "go")

    File.write!(Path.join([rel, "bin", "meerkat"]), ~S"""
    #!/usr/bin/env bash
    i=$(cat "$I_FILE"); echo $((i + 1)) > "$I_FILE"
    touch "$(dirname "$I_FILE")/beam-$((i + 1))"
    if [[ "$i" == 0 ]]; then exec sleep 60; fi
    while [[ ! -f "$GO_FILE" ]]; do sleep 0.05; done
    exit 7
    """)

    File.chmod!(Path.join([rel, "bin", "meerkat"]), 0o755)

    env = [
      {"MEERKAT_CURRENT_LINK", Path.join(dir, "current")},
      {"GO_FILE", go},
      {"INPUT_FILE", "/dev/null"}
    ]

    env = if deny_ps, do: [{"PATH", deny_ps_path(dir)} | env], else: env

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

    await_backend_pid(review.runs, 100, [review.backend])
    second
  end

  # The pid of a detached shepherd not in `known`, once a caller has
  # started it.
  defp await_backend_pid(runs, attempts \\ 100, known \\ []) do
    pids =
      Path.join([runs, "*", "pid"])
      |> Path.wildcard()
      # A caller may remove a run dir between the listing and the read.
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, pid} -> [String.trim(pid)]
          {:error, _} -> []
        end
      end)

    case Enum.reject(pids, &(&1 in known)) do
      [pid | _] ->
        pid

      [] when attempts > 0 ->
        Process.sleep(50)
        await_backend_pid(runs, attempts - 1, known)

      [] ->
        flunk("the caller started no backend in #{runs}")
    end
  end

  # The BEAM pid from the port file the backend's BEAM records.
  defp await_beam_pid(runs, attempts \\ 100) do
    beam =
      case Path.wildcard(Path.join([runs, "*", "port"])) do
        # Read between the BEAM's truncate and write, it is empty.
        [port_file | _] -> port_file |> File.read!() |> String.split() |> List.last()
        [] -> nil
      end

    case beam do
      beam when is_binary(beam) ->
        beam

      nil when attempts > 0 ->
        Process.sleep(50)
        await_beam_pid(runs, attempts - 1)

      nil ->
        flunk("no BEAM recorded its port in #{runs}")
    end
  end

  # Whether process `pid` exits within a second.
  defp await_gone(pid, attempts \\ 20) do
    case System.cmd("ps", ["-p", pid], stderr_to_stdout: true) do
      {_, 1} ->
        true

      _ when attempts > 0 ->
        Process.sleep(50)
        await_gone(pid, attempts - 1)

      _ ->
        false
    end
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
    # /dev/null otherwise.
    script = ~S"""
    if [ "$INPUT_FILE" = /dev/null ]; then exec "$0" "$@" </dev/null; fi
    cat "$INPUT_FILE" | "$0" "$@"
    """

    env = base |> Map.new() |> Map.merge(Map.new(env))

    # These BEAMs announce scripted ports but never serve HTTP. The caller
    # can catch a port file before the BEAM exits; a real curl would then
    # contact an unrelated service or wait indefinitely for a connection.
    # Refuse at that external boundary, keeping the caller, detach, restart
    # and exit-file delivery real. The FIFO makes that window deterministic
    # in the regression above without a delay or polling loop. The BEAM
    # opens its reader before announcing the port, so the signal cannot be
    # lost. Read/write opens and a bounded read also prevent a failed caller
    # from stranding a fixture process waiting for a peer that never arrives.
    http = Path.join(dir, "http")
    File.mkdir_p!(http)

    File.write!(
      Path.join(http, "curl"),
      Keyword.get(opts, :curl, ~S"""
      #!/usr/bin/env bash
      if [[ -n "${SHEPHERD_TEST_ATTACH_FIFO:-}" ]] && mkdir "$SHEPHERD_TEST_ATTACH_FIFO.sent" 2>/dev/null; then
        printf 'attach\n' 1<> "$SHEPHERD_TEST_ATTACH_FIFO"
      fi
      printf 's 000\n'
      exit 7
      """)
    )

    File.chmod!(Path.join(http, "curl"), 0o755)
    env = Map.put(env, "PATH", http <> ":" <> Map.get(env, "PATH", System.fetch_env!("PATH")))

    Port.open(
      {:spawn_executable, "/bin/sh"},
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
  defp await_result(port, dir, seen \\ "", timeout_ms \\ @timeout_ms) do
    receive do
      {^port, {:data, data}} -> await_result(port, dir, seen <> data, timeout_ms)
      {^port, {:exit_status, code}} -> {code, seen}
    after
      timeout_ms ->
        kill_launcher(port, dir)
        flunk("meerkat-shepherd did not exit within #{timeout_ms} ms:\n#{seen}")
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
    # and starts a BEAM that never exits.
    detached =
      for run <- Path.wildcard(Path.join([dir, "runs", "*"])),
          backend = await_file(Path.join(run, "pid")),
          do: backend

    if detached != [] do
      System.cmd("pkill", ["-9", "-P", Enum.join(detached, ",")])
      System.cmd("kill", ["-9" | detached])
    end
  end

  # The trimmed contents of `path` once it exists, or nil after 5 s.
  defp await_file(path, attempts \\ 100) do
    case File.read(path) do
      {:ok, contents} ->
        String.trim(contents)

      {:error, _} when attempts > 0 ->
        Process.sleep(50)
        await_file(path, attempts - 1)

      {:error, _} ->
        nil
    end
  end

  # The key naming the run dir of a review run with MEERKAT_PWD=`dir` and
  # the arguments every test here passes.
  defp run_key(dir) do
    :crypto.hash(:sha256, "#{dir}:--commit-msg /tmp/msg --no-open")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # Whether `path` holds `text` within 5 s.
  defp await_content(path, text, attempts \\ 100) do
    case File.read(path) do
      {:ok, contents} when contents == text <> "\n" ->
        true

      _ when attempts > 0 ->
        Process.sleep(50)
        await_content(path, text, attempts - 1)

      _ ->
        false
    end
  end

  # A PATH whose ps fails as Claude Code's sandbox makes it.
  defp deny_ps_path(dir) do
    fake_bin = Path.join(dir, "fakebin")
    File.mkdir_p!(fake_bin)
    ps = Path.join(fake_bin, "ps")
    File.write!(ps, "#!/bin/sh\necho 'ps: Operation not permitted' >&2\nexit 1\n")
    File.chmod!(ps, 0o755)
    fake_bin <> ":" <> System.get_env("PATH")
  end

  # Waits up to 5 s for `pattern` to match a path.
  defp await_match(pattern, attempts \\ 100) do
    cond do
      Path.wildcard(pattern) != [] ->
        :ok

      attempts > 0 ->
        Process.sleep(50)
        await_match(pattern, attempts - 1)

      true ->
        flunk("nothing matched #{pattern}")
    end
  end
end
