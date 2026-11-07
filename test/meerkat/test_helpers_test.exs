defmodule Meerkat.TestHelpersTest do
  use ExUnit.Case, async: true

  alias Meerkat.TestHelpers

  test "the suite's temp dir is named after this BEAM, so a later run can reap it" do
    assert System.tmp_dir!() =~ ~r"/meerkat-exunit/#{System.pid()}-\d+$"
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
      orphaned = Path.join(parent, "#{String.trim(exited)}-1")
      owned = Path.join(parent, "#{System.pid()}-1")
      unowned = Path.join(parent, "1-2-3")
      for dir <- [orphaned, owned, unowned], do: File.mkdir_p!(Path.join(dir, "repo"))

      TestHelpers.reap_orphaned_tmp_dirs(parent)

      refute File.exists?(orphaned), "dir of an exited BEAM is removed"
      assert File.exists?(owned), "dir of a live BEAM is kept"
      assert File.exists?(unowned), "dir without an owner pid is kept"
    end
  end

  test "fixture_template/2 keeps each repo's objects in one pack" do
    template =
      TestHelpers.fixture_template("fixture-template", fn dir ->
        work = Path.join(dir, "work")
        TestHelpers.git(dir, ["init", "-q", "--bare", "nested/remote.git"])
        TestHelpers.git(dir, ["init", "-q", "--initial-branch=main", work])
        TestHelpers.git(work, ["commit", "-q", "--allow-empty", "-m", "base"])
        TestHelpers.git(work, ["push", "-q", "../nested/remote.git", "main"])
      end)

    for repo <- ["work/.git", "nested/remote.git"] do
      objects = Path.join([template, repo, "objects"])
      assert [_] = Path.wildcard(Path.join(objects, "pack/*.pack"))
      assert Path.wildcard(Path.join(objects, "pack/*.bitmap")) == []
      assert Path.wildcard(Path.join(objects, "??")) == []
    end

    assert TestHelpers.git(Path.join(template, "work"), ["log", "--format=%s"]) == "base"
  end

  test "copy_fixture/2 points the copy's files at the copy, leaving object stores alone" do
    template = TestHelpers.tmp_path("copy-fixture-template")
    on_exit(fn -> File.rm_rf!(template) end)
    File.mkdir_p!(Path.join(template, "repo/.git/objects/ab"))
    File.write!(Path.join(template, "repo/.git/config"), "url = #{template}/remote.git\n")
    File.write!(Path.join(template, "repo/.git/objects/ab/cd"), "#{template}\n")
    File.ln_s!("config", Path.join(template, "repo/.git/link"))

    copy = TestHelpers.copy_fixture(template, "copy-fixture")

    assert File.read!(Path.join(copy, "repo/.git/config")) == "url = #{copy}/remote.git\n"
    assert File.read!(Path.join(copy, "repo/.git/objects/ab/cd")) == "#{template}\n"
    assert {:ok, "config"} = File.read_link(Path.join(copy, "repo/.git/link"))
    assert File.read!(Path.join(template, "repo/.git/config")) == "url = #{template}/remote.git\n"
  end
end
