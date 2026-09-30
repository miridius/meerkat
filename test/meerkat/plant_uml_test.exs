defmodule Meerkat.PlantUMLTest do
  # Swaps PATH and the BEAM-wide cached answer.
  use ExUnit.Case, async: false

  alias Meerkat.PlantUML

  setup do
    stub_dir =
      Path.join(System.tmp_dir!(), "meerkat-plantuml-#{System.unique_integer([:positive])}")

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
end
