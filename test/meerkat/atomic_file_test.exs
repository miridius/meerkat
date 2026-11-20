defmodule Meerkat.AtomicFileTest do
  use ExUnit.Case, async: true

  alias Meerkat.AtomicFile

  setup do
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-atomic-file-test")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "write/2" do
    test "writes content and returns :ok", %{dir: dir} do
      path = Path.join(dir, "out.txt")
      assert :ok = AtomicFile.write(path, "hello")
      assert File.read!(path) == "hello"
    end

    test "creates missing parent directories", %{dir: dir} do
      path = Path.join([dir, "deeply", "nested", "out.txt"])
      assert :ok = AtomicFile.write(path, "ok")
      assert File.read!(path) == "ok"
    end

    test "no tmp file remains on success", %{dir: dir} do
      path = Path.join(dir, "out.txt")
      assert :ok = AtomicFile.write(path, "ok")
      # No `out.txt.tmp.*` left behind.
      remaining = File.ls!(dir) |> Enum.filter(&String.contains?(&1, ".tmp."))
      assert remaining == []
    end

    test "concurrent writes both succeed; one wins", %{dir: dir} do
      path = Path.join(dir, "concurrent.txt")
      tasks = for i <- 1..5, do: Task.async(fn -> AtomicFile.write(path, "writer-#{i}") end)
      results = Enum.map(tasks, &Task.await/1)
      assert Enum.all?(results, &(&1 == :ok))
      assert File.read!(path) =~ "writer-"
    end

    test "a write that cannot land leaves no tmp file behind", %{dir: dir} do
      path = Path.join(dir, "taken")
      File.mkdir_p!(Path.join(path, "inside"))

      assert {:error, _} = AtomicFile.write(path, "body")

      assert dir |> File.ls!() |> Enum.sort() == [".git", "taken"]
    end

    test "a tmp file it cannot clean up is named on stderr", %{dir: dir} do
      blocker = Path.join(dir, "blocker")
      File.write!(blocker, "")
      path = Path.join(blocker, "out.txt")

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:error, _} = AtomicFile.write(path, "fail")
        end)

      assert stderr =~
               ~r/\Ameerkat: tmp cleanup at #{Regex.escape(path)}\.tmp\.\d+ failed: :enotdir\n\z/
    end

    test "returns {:error, _} when parent path is unwritable", %{dir: dir} do
      # mkdir a read-only dir, then attempt to write a file under it.
      ro_dir = Path.join(dir, "readonly")
      File.mkdir!(ro_dir)
      File.chmod!(ro_dir, 0o555)

      try do
        # The tmp file was never created, so there is nothing to clean
        # up and no cleanup failure to warn about.
        stderr =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            assert {:error, _} = AtomicFile.write(Path.join(ro_dir, "x.txt"), "fail")
          end)

        assert stderr == ""
      after
        File.chmod!(ro_dir, 0o755)
      end
    end
  end
end
