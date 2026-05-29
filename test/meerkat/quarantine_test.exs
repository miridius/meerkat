defmodule Meerkat.QuarantineTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Meerkat.Quarantine

  setup do
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-quarantine-test")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "move/4" do
    test "renames the file to <path>.corrupt.<ts> and warns", %{dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, "broken")

      log =
        capture_io(:stderr, fn ->
          assert :ok = Quarantine.move(path, "JSON parse failed", "thing", " Resetting.")
        end)

      refute File.exists?(path)

      assert File.ls!(dir)
             |> Enum.any?(&(String.starts_with?(&1, "bad.json.corrupt.") and &1 != "bad.json"))

      assert log =~ "thing at #{path} unusable (JSON parse failed)"
      assert log =~ "Resetting."
    end

    test "succeeds without a success suffix when caller omits one", %{dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, "x")

      log =
        capture_io(:stderr, fn ->
          assert :ok = Quarantine.move(path, "schema mismatch", "snapshot")
        end)

      refute File.exists?(path)
      assert log =~ "snapshot at #{path} unusable (schema mismatch)"
      # No trailing "Starting from ..." line.
      refute log =~ "Starting"
    end

    test "logs without success-suffix when rename fails (file missing)", %{dir: dir} do
      path = Path.join(dir, "never-existed.json")

      log =
        capture_io(:stderr, fn ->
          assert :ok = Quarantine.move(path, "missing", "thing", " WOULD-NOT-PRINT")
        end)

      assert log =~ "thing at #{path} unusable (missing)"
      # The success-only suffix must NOT appear when rename fails.
      refute log =~ "WOULD-NOT-PRINT"
    end
  end
end
