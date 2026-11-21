defmodule Meerkat.ShepherdTest do
  # Runs the real bin/meerkat-shepherd, through its caller half in
  # bin/lib/attach.ts, against a fake release BEAM whose per-iteration
  # exit codes are scripted. This pins the exit-code contract the prod
  # launcher rests on, and the port each launcher, prod and dev, prefers
  # for its BEAMs. bin/lib/attach.test.ts tests the caller's pieces.
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
  # commands, and dev checkouts. Each test's own dir holds what it sets up
  # and what its run writes.
  setup_all do
    on_exit(fn -> :persistent_term.erase({__MODULE__, :shared}) end)
    shared = Meerkat.TestHelpers.fixture_template("meerkat-shep-shared", &build_shared/1)
    :persistent_term.put({__MODULE__, :shared}, shared)
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
      assert seen == ["beam: 44444", "port file: none", "beam: 1"]
    end

    test "the dev launcher leaves no port file naming the exited BEAM" do
      seen = Enum.filter(dev_launcher_between_runs(), &String.starts_with?(&1, "port file:"))
      assert seen == ["port file: none"]
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

  # Each link in a chain of processes from a top process down to the caller
  # starts the next one as its own process group's leader ("job") or in its
  # own group ("fork"), and waits on it, as git commit waits on its hook.
  # The top exits once the caller, test/support/attach_probe.ts, has
  # recorded its ancestors.
  @link ~S"""
  [[ -n "$MK_TOP" ]] || export MK_TOP=$$
  [[ "$1" == job ]] && set -m
  # Each starts the next in the background, so bash forks it rather than
  # exec it.
  if (($# > 1)); then
    "$2" -c "$MK_LINK" link "${@:3}" &
  else
    bash -c "$MK_CALLER" caller &
  fi
  next=$!
  if [[ "$MK_TOP" == $$ ]]; then
    until [[ -f "$MK_DIR/recorded" ]] || ! kill -0 "$next" 2>/dev/null; do
      ((SECONDS < 60)) || exit 1
      sleep 0.05
    done
    [[ -f "$MK_DIR/recorded" ]] || { echo "the caller died before recording"; exit 1; }
  else
    wait "$next"
  fi
  """

  # A killed git commit, the top, leaves the decision held, whether it
  # leads the hook's group or a hook runner below it leads a group of its
  # own, as lefthook does. An app above git commit, or above the caller's
  # group leader with no git above, restarting leaves it to the caller. A
  # caller leading its own group checks only its parent. A fake git, a link
  # to bash, stands in for git commit; rows without one hide every git.
  for {name, top, chain, outcome} <- [
        {"its group leader exited while its hook lives", "bash", ~w(fork bash fork), :held},
        {"git above its hook runner's group exited", "git", ~w(job bash fork), :held},
        {"an app above its git group leader exited", "bash", ~w(job git fork), :delivered},
        {"a process above its group leader exited", "bash", ~w(job bash fork), :delivered},
        {"its parent exited while it leads its group", "bash", ~w(job), :held},
        {"its grandparent exited while it leads its group", "bash", ~w(fork bash job), :delivered}
      ] do
    test "a caller given the decision after #{name}: #{outcome}" do
      dir = test_dir()
      git = Path.join(dir, "git")
      File.ln_s!(System.find_executable("bash"), git)

      [top | chain] =
        Enum.map([unquote(top) | unquote(chain)], &if(&1 == "git", do: git, else: &1))

      {output, 0} =
        System.cmd(top, ["-c", @link, "top" | chain],
          env: [
            {"MK_LINK", @link},
            {"MK_CALLER", ~S(exec bun "$MK_PROBE")},
            {"MK_PROBE", Path.expand("test/support/attach_probe.ts")},
            {"MK_DIR", dir},
            {"MK_HIDE", if(git in [top | chain], do: "", else: "1")}
          ]
        )

      if unquote(outcome) == :delivered do
        assert output == "outcome\ndelivered\n"
      else
        assert output == @orphaned
      end
    end
  end

  # A waiting caller relays its backend's log every 0.2 s tick and checks
  # its ancestors only once the decision arrives, so it forks nothing per
  # tick. The backend writes each next line only once the test has seen
  # the last one relayed, so the quiet stream spans at least five relays,
  # each on its own tick.
  test "a caller waiting on a decision runs no process while it relays the backend's log" do
    dir = test_dir()
    calls = Path.join(dir, "calls")
    acks = Path.join(dir, "acks")
    delivered = Path.join(dir, "delivered")
    File.mkdir_p!(acks)

    # The attach stream stays quiet until the test has seen every tick.
    http =
      start_backend(fn conn ->
        case conn.request_path do
          "/api/attach/delivered" ->
            File.touch!(delivered)
            Plug.Conn.send_resp(conn, 200, "")

          "/api/attach" ->
            File.write!(calls, "start\n", [:append])
            {:ok, conn} = conn |> Plug.Conn.send_chunked(200) |> Plug.Conn.chunk("k\n")
            eventually(fn -> File.exists?(Path.join(acks, "6")) end, timeout: @timeout_ms)
            File.write!(calls, "end\n", [:append])
            {:ok, conn} = Plug.Conn.chunk(conn, "x 0\n")
            conn
        end
      end)

    release =
      fake_release(~S"""
      echo "$HTTP_PORT $$" > "$MEERKAT_SERVE_DIR/port"
      # The backend runs in its own session, so a failed test cannot kill it;
      # it exits once the test's own waits (@timeout_ms) are surely over.
      for k in {1..6}; do
        echo "tick $k" >&2
        until [[ -f "$ACKS/$k" ]]; do ((SECONDS < 200)) || exit 1; sleep 0.05; done
      done
      until [[ -f "$DELIVERED" ]]; do ((SECONDS < 200)) || exit 1; sleep 0.05; done
      """)

    port =
      open_launcher(
        @shepherd,
        ["--commit-msg", "/tmp/msg", "--no-open"],
        dir,
        release ++
          [
            {"INPUT_FILE", "/dev/null"},
            {"HTTP_PORT", to_string(http)},
            {"CALLS", calls},
            {"ACKS", acks},
            {"DELIVERED", delivered},
            # Each logs its run to $CALLS, then runs the real command.
            {"PATH", shared("logged") <> ":" <> System.get_env("PATH")}
          ]
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

  # A BEAM that never binds, so the review has no URL yet and the caller
  # stops it, or one that has served the review on a backend that answers
  # the caller's leave with `open`. It says when it has started: a
  # shepherd stopped before it traps signals dies without recording an exit
  # code. The signal goes to the caller's whole process group, so it also
  # kills whatever the caller is running at the time. bin/lib/attach.test.ts
  # tests the caller's leave against every other answer.
  for {signal, number, backend, open?} <- [
        {"TERM", 15, "starts", false},
        {"INT", 2, "starts", false},
        {"HUP", 1, "starts", false},
        {"TERM", 15, "answers that the review is open", true}
      ] do
    test "a caller whose process group gets SIG#{signal} while its backend #{backend} prints only what to do and dies of the signal" do
      dir = test_dir()
      started = Path.join(dir, "beam-started")
      caller_pid_file = Path.join(dir, "caller-pid")

      # The attach is refused, so the caller keeps trying until stopped.
      http =
        start_backend(fn conn ->
          case conn.request_path do
            "/api/attach/leave" -> Plug.Conn.send_resp(conn, 200, "open")
            _ -> Plug.Conn.send_resp(conn, 500, "")
          end
        end)

      beam =
        if unquote(open?),
          do:
            ~S|touch "$MEERKAT_SERVE_DIR/served"; echo "$HTTP_PORT $$" >"$MEERKAT_SERVE_DIR/port"|,
          else: ""

      port =
        open_launcher(
          @shepherd,
          ["--commit-msg", "/tmp/msg", "--no-open"],
          dir,
          fake_release("#{beam}\ntouch \"$BEAM_STARTED\"\nexec sleep 60\n") ++
            [
              {"BEAM_STARTED", started},
              {"CALLER_PID_FILE", caller_pid_file},
              {"HTTP_PORT", to_string(http)}
            ],
          own_group: true
        )

      runs = Path.join(dir, "runs")
      backend = await_backend_pid(runs)

      # The shepherd writes `exit` into its run dir after the TERM;
      # deleting the dir before then races that write. Not every run dir
      # gets an `exit`, so each wait gets 10 s, not @timeout_ms: several
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

      said =
        if unquote(open?),
          do:
            "The review is still open at http://127.0.0.1:#{http}/; run the same command again to wait for its outcome.\n",
          else: @rerun

      assert output ==
               "meerkat: stopped waiting (SIG#{unquote(signal)}) before the review completed. " <>
                 said

      unless unquote(open?) do
        [run] = Path.wildcard(Path.join(runs, "*.*"))
        assert await_file(Path.join(run, "exit")) == "143"
      end
    end
  end

  # A signal to the caller's whole process group can kill the ps a poll runs
  # to check the backend before the caller's trap runs, as under load. Here
  # that ps kills itself, and the group is signalled once a later poll checks
  # the backend again.
  test "a caller whose check of its backend is killed by a signal does not take the backend for dead" do
    dir = test_dir()
    runs = Path.join(dir, "runs")
    started = Path.join(dir, "beam-started")
    trigger = Path.join(dir, "trigger")
    checked = Path.join(dir, "checked-again")
    caller_pid_file = Path.join(dir, "caller-pid")

    executable(Path.join(dir, "bin/ps"), ~S"""
    #!/usr/bin/env bash
    if [[ "$*" == *command=* ]]; then
      [[ -e "$KILLED" ]] && touch "$CHECKED"
      if rm "$TRIGGER" 2>/dev/null; then touch "$KILLED"; kill -TERM $$; fi
    fi
    exec /bin/ps "$@"
    """)

    port =
      open_launcher(
        @shepherd,
        ["--commit-msg", "/tmp/msg", "--no-open"],
        dir,
        fake_release("touch \"$BEAM_STARTED\"\nexec sleep 60\n") ++
          [
            {"BEAM_STARTED", started},
            {"CALLER_PID_FILE", caller_pid_file},
            {"TRIGGER", trigger},
            {"KILLED", Path.join(dir, "killed")},
            {"CHECKED", checked},
            {"PATH", Path.join(dir, "bin") <> ":" <> System.fetch_env!("PATH")}
          ],
        own_group: true
      )

    backend = await_backend_pid(runs)

    on_exit(fn ->
      System.cmd("kill", ["-TERM", backend], stderr_to_stdout: true)

      for run <- Path.wildcard(Path.join(runs, "*")),
          do: await_file(Path.join(run, "exit"), 10_000)
    end)

    assert await_file(started) == ""
    File.write!(trigger, "")
    # A caller that took the backend for dead has already exited.
    eventually(fn -> File.exists?(checked) or Port.info(port) == nil end, timeout: @timeout_ms) ||
      flunk("the caller did not check its backend again")

    System.cmd("kill", ["-TERM", "-" <> await_file(caller_pid_file)], stderr_to_stdout: true)

    assert {143, output} = await_result(port, dir)
    assert output == "meerkat: stopped waiting (SIGTERM) before the review completed. " <> @rerun
    [run] = Path.wildcard(Path.join(runs, "*.*"))
    assert await_file(Path.join(run, "exit")) == "143"
  end

  # The attach is refused, so neither caller hears from the backend; a leave
  # is logged and answered as if it ended the review.
  for {shown, served?} <- [{"has not shown", false}, {"has shown", true}] do
    test "a rerun stopped before it hears from a backend that #{shown} the review only hands it back to the caller it replaced" do
      dir = test_dir()
      runs = Path.join(dir, "runs")
      rerun_pid_file = Path.join(dir, "rerun-pid")
      leaves = Path.join(dir, "leaves")

      http =
        start_backend(fn conn ->
          case conn.request_path do
            "/api/attach/leave" ->
              File.write!(leaves, conn.query_string <> "\n", [:append])
              Plug.Conn.send_resp(conn, 200, "ended")

            _ ->
              Plug.Conn.send_resp(conn, 500, "")
          end
        end)

      beam =
        if unquote(served?),
          do:
            ~S|touch "$MEERKAT_SERVE_DIR/served"; echo "$HTTP_PORT $$" >"$MEERKAT_SERVE_DIR/port"|,
          else: ""

      env =
        fake_release("#{beam}\nexec sleep 60\n") ++
          [{"INPUT_FILE", "/dev/null"}, {"HTTP_PORT", to_string(http)}]

      first = open_launcher(@shepherd, ["--commit-msg", "/tmp/msg", "--no-open"], dir, env)

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
          env ++ [{"CALLER_PID_FILE", rerun_pid_file}],
          own_group: true
        )

      rerun_pid = await_file(rerun_pid_file)
      [caller] = Path.wildcard(Path.join([runs, "*.*", "caller"]))
      assert eventually(fn -> File.read!(caller) == "#{rerun_pid}\n" end, timeout: @timeout_ms)
      System.cmd("kill", ["-TERM", "-" <> rerun_pid])

      assert {143, output} = await_result(rerun, dir)

      assert output ==
               "meerkat: stopped waiting (SIGTERM) before the review completed. Run the same command again.\n"

      assert File.read!(caller) == "#{first_pid}\n"
      # The caller sends a leave before it exits, so none was sent.
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
      old = Path.join([dir, "runs", run_key(dir)])
      File.mkdir_p!(old)
      File.write!(Path.join(old, "exit"), "5\n")

      env =
        fake_release(~s(echo "$MEERKAT_PREFERRED_PORT" > "$PORT_SEEN"\nexit 76\n)) ++
          [
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

      assert File.read!(Path.join(root, "_build/dev/.meerkat-root")) == physical(root) <> "\n"
    end

    test "the dev shepherd skips `mix compile` for a fresh build compiled in its own checkout" do
      {port, dir, _} = open_dev_shepherd(compile_code: 1, built: :root, exit_codes: [76])

      assert await_exit(port, dir) == 0
    end
  end

  # The fake BEAM of `port_file_between_runs/4`. After the first, it
  # records whether the run dir still holds the last BEAM's `port` file,
  # as `port file: stale` or `port file: none`. It records the preferred
  # port it saw as `beam: <port>` (`beam: none` if unset) and its
  # SECRET_KEY_BASE as `secret: <value>`, writes its port file and exits
  # 75, then 76, approving.
  @between_beam ~S"""
  i=$(cat "$I_FILE"); echo $((i + 1)) > "$I_FILE"
  if [[ "$i" != 0 ]]; then
    if [[ -f "$MEERKAT_SERVE_DIR/port" ]]; then echo "port file: stale"; else echo "port file: none"; fi >> "$SEEN_FILE"
  fi
  echo "beam: ${MEERKAT_PREFERRED_PORT:-none}" >> "$SEEN_FILE"
  echo "secret: ${SECRET_KEY_BASE:-none}" >> "$SEEN_FILE"
  echo "$((i + 1)) $$" > "$MEERKAT_SERVE_DIR/port"
  if [[ "$i" == 0 ]]; then exit 75; fi
  exit 76
  """

  defp build_shared(shared) do
    # The release prod tests run. Its BEAM is the script in
    # $FAKE_BEAM, run by this bash so that its args, `$$` and `exec` are
    # the BEAM's own. A BEAM started once its run dir is gone crashes, so
    # a shepherd that outlived its test aborts after its one crash retry.
    executable(Path.join(shared, "rel/bin/meerkat"), ~S"""
    #!/usr/bin/env bash
    if [[ -n "${MEERKAT_SERVE_DIR:-}" && ! -d "$MEERKAT_SERVE_DIR" ]]; then exit 2; fi
    eval "$FAKE_BEAM"
    """)

    File.ln_s!(Path.join(shared, "rel"), Path.join(shared, "current"))

    # A ps that fails as Claude Code's sandbox makes it.
    executable(
      Path.join(shared, "deny-ps/ps"),
      "#!/bin/sh\necho 'ps: Operation not permitted' >&2\nexit 1\n"
    )

    for tool <- ~w(ps) do
      executable(
        Path.join([shared, "logged", tool]),
        ~s(#!/bin/sh\necho #{tool} >> "$CALLS"\nexec #{System.find_executable(tool)} "$@"\n)
      )
    end

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

    # The dev stubs of `port_file_between_runs/4`: `mix compile` and the
    # asset build succeed, and `mix run` is the BEAM.
    executable(
      Path.join(shared, "between/dev/mix"),
      "#!/usr/bin/env bash\nif [[ \"$1\" != run ]]; then exit 0; fi\n" <> @between_beam
    )

    executable(Path.join(shared, "between/dev/bunx"), "#!/usr/bin/env bash\nexit 0\n")
    File.mkdir_p!(Path.join(shared, "between/prod"))

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
  if [[ -n "${MEERKAT_SERVE_DIR:-}" ]]; then echo "$((i + 1)) $$" > "$MEERKAT_SERVE_DIR/port"; fi
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
  # first on PATH: the dev stubs' `mix run` is the BEAM, and for prod
  # `env` names the release. Returns what the BEAMs recorded, in order and
  # without repeats.
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
    # The plain one has no `_build/dev`, so its stamp is never written.
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

    File.cp!(Path.join(File.cwd!(), "bin/meerkat-beam"), Path.join(root, "bin/meerkat-beam"))
    File.cp_r!(Path.join(File.cwd!(), "bin/lib"), Path.join(root, "bin/lib"))
    File.chmod!(Path.join([root, "bin", "meerkat-beam"]), 0o755)

    if built do
      source = Path.join(root, "lib/meerkat.ex")
      manifest = Path.join(root, "_build/dev/lib/meerkat/.mix/compile.elixir")
      File.mkdir_p!(Path.dirname(source))
      File.mkdir_p!(Path.dirname(manifest))
      File.write!(source, "")
      File.touch!(source, {{2020, 1, 1}, {0, 0, 0}})
      File.write!(manifest, "")
      stamp = if built == :root, do: physical(root), else: built
      File.write!(Path.join(root, "_build/dev/.meerkat-root"), stamp <> "\n")
    end

    root
  end

  # `path` with its symlinks resolved, as the dev launcher names its checkout.
  defp physical(path) do
    {out, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(out)
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
  # `opts[:cd]` sets its working directory.
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

    env = base |> Map.new() |> Map.merge(Map.new(env))

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
    # the test; once the shared stubs are deleted at the module's end, a
    # dev one runs the real `mix` and starts a BEAM that never exits. Not
    # every run dir gets a pid, so each wait gets 10 s, not @timeout_ms:
    # after a wait that timed out, @timeout_ms of the 180 s test timeout
    # is already spent.
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

  # Serves a stand-in for a review backend's attach API on a loopback port,
  # which it returns, answering each request with `answer`, a function of
  # the conn.
  defp start_backend(answer) do
    pid =
      start_supervised!(
        {Bandit, plug: {__MODULE__.Backend, answer}, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defmodule Backend do
    @moduledoc false
    def init(answer), do: answer
    def call(conn, answer), do: answer.(conn)
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
