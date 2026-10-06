defmodule Meerkat.TestHelpersTest do
  use ExUnit.Case, async: true

  alias Meerkat.TestHelpers

  test "the suite's temp dir is named after this BEAM, so a later run can reap it" do
    assert Path.basename(System.tmp_dir!()) =~ ~r/^meerkat-exunit-#{System.pid()}-\d+$/
  end

  describe "reap_orphaned_tmp_dirs/1" do
    setup do
      parent = Path.join(System.tmp_dir!(), "reap-#{System.unique_integer([:positive])}")
      File.mkdir_p!(parent)
      on_exit(fn -> File.rm_rf!(parent) end)
      %{parent: parent}
    end

    test "removes the dirs of exited BEAMs and keeps those of live ones and unowned dirs",
         %{parent: parent} do
      {exited, 0} = System.cmd("sh", ["-c", "echo $$"])
      orphaned = Path.join(parent, "meerkat-exunit-#{String.trim(exited)}-1")
      owned = Path.join(parent, "meerkat-exunit-#{System.pid()}-1")
      # Named like the temp dirs tests made before suites had their own.
      unowned = Path.join(parent, "meerkat-lv-1-2-3")
      for dir <- [orphaned, owned, unowned], do: File.mkdir_p!(Path.join(dir, "repo"))

      TestHelpers.reap_orphaned_tmp_dirs(parent)

      refute File.exists?(orphaned), "dir of an exited BEAM is removed"
      assert File.exists?(owned), "dir of a live BEAM is kept"
      assert File.exists?(unowned), "dir without an owner pid is kept"
    end
  end
end
