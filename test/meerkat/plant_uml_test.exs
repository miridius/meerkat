defmodule Meerkat.PlantUMLTest do
  # Swaps PATH and the BEAM-wide cached answer.
  use Meerkat.Case, async: false

  alias Meerkat.PlantUML

  setup do
    stub_dir =
      Meerkat.TestHelpers.tmp_path("meerkat-plantuml")

    File.mkdir_p!(stub_dir)
    calls = Path.join(stub_dir, "calls")
    prev_path = System.get_env("PATH")
    :persistent_term.erase({PlantUML, :available?})

    on_exit(fn ->
      System.put_env("PATH", prev_path)
      :persistent_term.erase({PlantUML, :available?})
      File.rm_rf!(stub_dir)
    end)

    System.put_env("PATH", stub_dir <> ":" <> prev_path)
    %{stub_dir: stub_dir, calls: calls}
  end

  # A `plantuml` that records each run and exits with `code`.
  defp stub_plantuml(%{calls: calls} = ctx, code) do
    stub(ctx, "plantuml", "echo \"$@\" >> '#{calls}'\nexit #{code}")
  end

  # An executable `name` on the test's PATH that runs the sh `body`.
  defp stub(%{stub_dir: dir}, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
  end

  # A real child that prints nothing and outlives any time budget a test
  # passes; collect/3 kills it when the budget runs out.
  defp stuck_port do
    Port.open(
      {:spawn_executable, System.find_executable("sleep")},
      [:binary, :exit_status, :stderr_to_stdout, :use_stdio, args: ["30"]]
    )
  end

  # A port with no OS process, a loopback listening socket: it sends
  # nothing, and nothing outlives the test.
  defp processless_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    socket
  end

  # sh that sets `$m` to whether the script's stderr is its stdout.
  @stderr_check "if [ /dev/fd/1 -ef /dev/fd/2 ]; then m=merged; else m=split; fi"

  defp runs(%{calls: calls}) do
    case File.read(calls) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  test "a plantuml whose -version succeeds is available, and later asks reuse the answer", ctx do
    stub_plantuml(ctx, 0)

    assert PlantUML.available?()
    assert PlantUML.available?()
    assert runs(ctx) == 1
  end

  test "a plantuml whose -version fails is unavailable, and later asks reuse the answer", ctx do
    stub_plantuml(ctx, 1)

    refute PlantUML.available?()
    refute PlantUML.available?()
    assert runs(ctx) == 1
  end

  test "the probe runs plantuml -version with its stderr folded into the captured output",
       %{calls: calls} = ctx do
    stub(ctx, "plantuml", "#{@stderr_check}\necho \"$* $m\" >> '#{calls}'")

    assert PlantUML.available?()
    assert File.read!(calls) == "-version merged\n"
  end

  test "no plantuml on PATH is unavailable and fails a render", %{stub_dir: dir} do
    System.put_env("PATH", dir)
    refute PlantUML.available?()

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert PlantUML.render("@startuml\n@enduml\n") ==
               {:error, "plantuml binary not found on PATH"}
    end)
  end

  test "render/1 rejects source that is not a binary" do
    not_binary = Process.get(:not_binary, 42)
    assert_raise FunctionClauseError, fn -> PlantUML.render(not_binary) end
  end

  describe "a render plantuml fails" do
    setup do
      previous = System.get_env("PLANTUML_SECURITY_PROFILE")
      on_exit(fn -> restore_env("PLANTUML_SECURITY_PROFILE", previous) end)
      System.delete_env("PLANTUML_SECURITY_PROFILE")
    end

    test "returns and logs plantuml's exit code and stderr, run under the SANDBOX profile",
         %{calls: calls} = ctx do
      stub(ctx, "plantuml", """
      echo "$PLANTUML_SECURITY_PROFILE" >> '#{calls}'
      echo '  Syntax Error? (line 2)  ' >&2
      exit 3\
      """)

      reason = "plantuml exited 3.\nplantuml output:\nSyntax Error? (line 2)"

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert PlantUML.render("@startuml\nnot valid\n@enduml\n") == {:error, reason}
        end)

      assert stderr == "meerkat: plantuml render failed — #{reason}\n"
      assert File.read!(calls) == "SANDBOX\n"
    end
  end

  describe "collect/3" do
    test "returns what a child that exits 0 printed, as one binary" do
      port =
        Port.open(
          {:spawn_executable, "/bin/sh"},
          [:binary, :exit_status, :stderr_to_stdout, args: ["-c", "printf x"]]
        )

      assert PlantUML.collect_for_test(port, [], 5_000) == {:ok, "x"}
    end

    # Only the time spent waiting counts, so output that comes early leaves
    # nearly the whole budget for the exit that follows it.
    test "keeps waiting for the exit after output, within the budget" do
      port = processless_port()
      me = self()

      spawn_link(fn ->
        send(me, {port, {:data, "."}})
        Process.sleep(50)
        send(me, {port, {:exit_status, 0}})
      end)

      assert PlantUML.collect_for_test(port, [], 30_000) == {:ok, "."}
      Port.close(port)
    end

    # The feeder outlasts the budget many times over, so a budget that
    # restarts or grows with each chunk would collect every chunk.
    test "counts the time spent receiving output against the budget" do
      port = stuck_port()
      me = self()
      chunks = 150

      feeder =
        spawn_link(fn ->
          for _ <- 1..chunks do
            send(me, {port, {:data, "."}})
            Process.sleep(10)
          end
        end)

      assert {:error, msg} = PlantUML.collect_for_test(port, [], 300)
      Process.unlink(feeder)
      Process.exit(feeder, :kill)

      [_, partial] = String.split(msg, "plantuml output before the timeout:\n")
      assert String.length(partial) < chunks
    end

    # Each chunk's receive is timed in whole milliseconds, so across this
    # many chunks some take 1 ms and drive the budget below zero, where it
    # must stay at zero.
    test "keeps a spent budget at zero however much output is queued" do
      port = stuck_port()
      chunks = 100_000
      for _ <- 1..chunks, do: send(self(), {port, {:data, "."}})

      assert {:error, msg} = PlantUML.collect_for_test(port, [], 0)
      assert String.ends_with?(msg, "\n" <> String.duplicate(".", chunks))
    end

    # A tracer sends the exit the moment the collector waits inside
    # collect/3. With the budget spent, collect/3 must not wait at all.
    test "with the budget spent after output, times out without waiting" do
      parent = self()

      {collector, ref} =
        spawn_monitor(fn ->
          port = processless_port()
          send(parent, {:port, port})
          receive do: (:go -> :ok)
          send(self(), {port, {:data, "."}})
          send(parent, {:result, PlantUML.collect_for_test(port, [], 0)})
        end)

      assert_receive {:port, port}
      previous_priority = Process.flag(:priority, :high)

      try do
        :erlang.trace(collector, true, [:running, {:tracer, self()}])
        send(collector, :go)
        assert {:error, "plantuml did not finish" <> _} = await_collector(collector, ref, port)
      after
        Process.flag(:priority, previous_priority)
      end
    end
  end

  defp await_collector(collector, ref, port) do
    receive do
      {:result, result} ->
        result

      {:DOWN, ^ref, :process, ^collector, reason} ->
        {:crashed, reason}

      {:trace, ^collector, :out, {PlantUML, :collect, 3}} ->
        if Process.info(collector, [:status, :current_function]) ==
             [status: :waiting, current_function: {PlantUML, :collect, 3}] do
          send(collector, {port, {:exit_status, 0}})
        end

        await_collector(collector, ref, port)

      {:trace, ^collector, _, _} ->
        await_collector(collector, ref, port)
    end
  end

  # Puts the render time budget back as it was when the test ends.
  defp keep_timeout_env(_ctx) do
    previous = Application.fetch_env(:meerkat, :plantuml_timeout_ms)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:meerkat, :plantuml_timeout_ms, value)
        :error -> Application.delete_env(:meerkat, :plantuml_timeout_ms)
      end
    end)
  end

  describe "timeout_ms/0" do
    setup :keep_timeout_env

    test "is 30 s unless the app env sets it" do
      Application.delete_env(:meerkat, :plantuml_timeout_ms)
      assert PlantUML.timeout_ms() == 30_000

      Application.put_env(:meerkat, :plantuml_timeout_ms, 5)
      assert PlantUML.timeout_ms() == 5
    end
  end

  describe "a render that runs out of time" do
    setup :keep_timeout_env
    setup do: Application.put_env(:meerkat, :plantuml_timeout_ms, 30_000)

    test "with no output says only that plantuml was killed" do
      assert {:error, msg} = PlantUML.collect_for_test(stuck_port(), [], 0)
      assert msg == "plantuml did not finish within 30000ms; the process was killed."
    end

    # The killed child's port can close before or after the cleanup closes
    # it; repeating the timeout covers both orders.
    test "returns the timeout error however soon the killed child's port closes" do
      for _ <- 1..20 do
        assert {:error, "plantuml did not finish" <> _} =
                 PlantUML.collect_for_test(stuck_port(), [], 0)
      end
    end

    test "with output also shows what plantuml printed before the timeout" do
      assert {:error, msg} = PlantUML.collect_for_test(stuck_port(), ["  Syntax error?\n"], 0)

      assert msg ==
               "plantuml did not finish within 30000ms; the process was killed.\n" <>
                 "plantuml output before the timeout:\nSyntax error?"
    end

    test "SIGKILLs the child, with kill's stderr folded into its captured output",
         %{calls: calls} = ctx do
      # `kill` in sh is the builtin, not this stub.
      stub(ctx, "kill", "#{@stderr_check}\necho \"$* $m\" >> '#{calls}'\nkill \"$@\"")
      port = stuck_port()
      {:os_pid, pid} = Port.info(port, :os_pid)

      assert {:error, _} = PlantUML.collect_for_test(port, [], 0)
      assert File.read!(calls) == "-KILL #{pid} merged\n"
      assert eventually_gone?(pid)
    end

    test "closes a port that has no OS process without killing anything", %{calls: calls} = ctx do
      stub(ctx, "kill", "echo \"$*\" >> '#{calls}'")
      socket = processless_port()

      assert {:error, _} = PlantUML.collect_for_test(socket, [], 0)
      assert Port.info(socket) == nil
      refute File.exists?(calls)
    end
  end

  # True once OS process `pid` has exited (a zombie counts). Each probe
  # starts a `ps`, so probes come 50 ms apart.
  defp eventually_gone?(pid) do
    Meerkat.TestHelpers.eventually(
      fn ->
        case System.cmd("ps", ["-o", "stat=", "-p", to_string(pid)]) do
          {_, 1} -> true
          {"Z" <> _, 0} -> true
          _ -> false
        end
      end,
      interval: 50
    )
  end

  # Runs the real `plantuml` binary; CI installs it.
  describe "render/1" do
    test "returns the SVG for valid source" do
      assert {:ok, svg} = PlantUML.render("@startuml\nAlice -> Bob\n@enduml\n")
      assert svg =~ "<svg"
      assert svg =~ "Alice"
    end

    test "a syntax error's reason is plantuml's diagnosis, not its error-image SVG" do
      assert {:error, reason} =
               PlantUML.render("@startuml\nAlice -> Bob\nthis is not valid\n@enduml\n")

      assert reason =~ "Syntax Error?"
      refute reason =~ "<svg"
    end
  end

  describe "render/1's tmp files" do
    setup %{stub_dir: stub_dir} do
      tmp = Path.join(stub_dir, "tmp")
      File.mkdir_p!(tmp)
      prev_tmpdir = System.get_env("TMPDIR")
      on_exit(fn -> restore_env("TMPDIR", prev_tmpdir) end)
      System.put_env("TMPDIR", tmp)
      %{tmp: tmp}
    end

    test "are removed after a successful render and after a failed one", %{tmp: tmp} do
      assert {:ok, _} = PlantUML.render("@startuml\nAlice -> Bob\n@enduml\n")
      assert {:error, _} = PlantUML.render("@startuml\nthis is not valid\n@enduml\n")
      assert File.ls!(tmp) == []
    end

    # A plantuml that exits 0 but whose SVG is gone by the time it is read.
    test "an SVG that cannot be read is an error, not a crash", %{tmp: tmp} = ctx do
      stub(ctx, "plantuml", "rm -f '#{tmp}'/meerkat-puml-*.svg\nexit 0")

      assert {:error, reason} = PlantUML.render("@startuml\nAlice -> Bob\n@enduml\n")
      assert reason =~ ~r/^reading .*\.svg failed: no such file or directory$/
    end

    test "are named for this OS process and a unique number", %{calls: calls, tmp: tmp} = ctx do
      stub(ctx, "plantuml", "ls '#{tmp}' >> '#{calls}'")

      for _ <- 1..2, do: assert({:ok, ""} = PlantUML.render("@startuml\n@enduml\n"))

      names = calls |> File.read!() |> String.split("\n", trim: true)
      assert [a_puml, a_svg, b_puml, b_svg] = names
      base = ~r/^meerkat-puml-#{System.pid()}-\d+$/

      for {puml, svg} <- [{a_puml, a_svg}, {b_puml, b_svg}] do
        assert Path.extname(puml) == ".puml"
        assert Path.rootname(svg, ".svg") == Path.rootname(puml, ".puml")
        assert Path.rootname(puml, ".puml") =~ base
      end

      refute a_puml == b_puml
    end

    # A directory without search permission still looks writable to
    # System.tmp_dir!/0, but no file can be created in it.
    test "a source file that cannot be written is an error", %{tmp: tmp} do
      File.chmod!(tmp, 0o600)

      try do
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:error, reason} = PlantUML.render("@startuml\n@enduml\n")
          path = ~r/^writing #{Regex.escape(tmp)}\/meerkat-puml-\d+-\d+\.puml failed: /
          assert reason =~ path
          assert String.ends_with?(reason, ".puml failed: permission denied")
        end)
      after
        File.chmod!(tmp, 0o755)
      end
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
