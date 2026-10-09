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
  defp stub_plantuml(%{stub_dir: dir, calls: calls}, code) do
    path = Path.join(dir, "plantuml")
    File.write!(path, "#!/bin/sh\necho \"$@\" >> '#{calls}'\nexit #{code}\n")
    File.chmod!(path, 0o755)
  end

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

  describe "a render that runs out of time" do
    # A real child that outlives the time budget; 0ms makes it time out at once.
    defp stuck_port do
      Port.open(
        {:spawn_executable, System.find_executable("sleep")},
        [:binary, :exit_status, :stderr_to_stdout, :use_stdio, args: ["30"]]
      )
    end

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
    test "an SVG that cannot be read is an error, not a crash", %{stub_dir: dir, tmp: tmp} do
      path = Path.join(dir, "plantuml")
      File.write!(path, "#!/bin/sh\nrm -f '#{tmp}'/meerkat-puml-*.svg\nexit 0\n")
      File.chmod!(path, 0o755)

      assert {:error, reason} = PlantUML.render("@startuml\nAlice -> Bob\n@enduml\n")
      assert reason =~ ~r/^reading .*\.svg failed: no such file or directory$/
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
