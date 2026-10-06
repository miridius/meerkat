defmodule Meerkat.GitHeldIndexTest do
  use ExUnit.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, stage: 3, temporary_index: 3]

  alias Meerkat.Git

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    dir = Meerkat.TestHelpers.make_git_repo("meerkat-held-index")
    git(dir, ["config", "user.email", "t@t.t"])
    git(dir, ["config", "user.name", "t"])
    stage(dir, "a.txt", "base\n")
    git(dir, ["commit", "-qm", "base"])

    held_dir = Path.join(dir, ".git/run")
    File.mkdir_p!(held_dir)

    previous = System.get_env("GIT_INDEX_FILE")

    on_exit(fn ->
      if previous,
        do: System.put_env("GIT_INDEX_FILE", previous),
        else: System.delete_env("GIT_INDEX_FILE")

      Application.delete_env(:meerkat, :held_index)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir, held_dir: held_dir}
  end

  test "reads of a temporary index still see it once git has deleted it",
       %{dir: dir, held_dir: held_dir} do
    index = temporary_index(dir, "index.lock", %{"a.txt" => "all\n"})
    System.put_env("GIT_INDEX_FILE", index)

    Git.hold_temporary_index(dir, held_dir)
    File.rm!(index)

    assert {:ok, [%{file_name: "a.txt", new_content: "all\n"} = file]} =
             Git.staged_file_diffs(dir)

    assert {:ok, file.effective_oid} == Git.fetch_staged_blob_oid(dir, "a.txt")
    assert file.effective_oid == git(dir, ["hash-object", "a.txt"])
  end

  test "a restarted BEAM finds the copy the one before it took", %{dir: dir, held_dir: held_dir} do
    index = temporary_index(dir, "next-index-7.lock", %{"a.txt" => "by path\n"})
    System.put_env("GIT_INDEX_FILE", index)
    Git.hold_temporary_index(dir, held_dir)
    File.rm!(index)
    Application.delete_env(:meerkat, :held_index)

    Git.hold_temporary_index(dir, held_dir)

    assert {:ok, [%{file_name: "a.txt", new_content: "by path\n"}]} = Git.staged_file_diffs(dir)
  end

  test "the repository's own index is read where it lives, however its path is spelled",
       %{dir: dir, held_dir: held_dir} do
    stage(dir, "a.txt", "first\n")

    for name <- [".git/index", Path.join(dir, ".git/index"), Path.join(dir, ".git/../.git/index")] do
      System.put_env("GIT_INDEX_FILE", name)
      Git.hold_temporary_index(dir, held_dir)
    end

    stage(dir, "a.txt", "second\n")

    refute File.exists?(Path.join(held_dir, "index"))
    assert {:ok, [%{new_content: "second\n"}]} = Git.staged_file_diffs(dir)
  end

  test "a relative name is taken from the top of the work tree, as git takes it",
       %{dir: dir, held_dir: held_dir} do
    sub = Path.join(dir, "sub")
    File.mkdir_p!(sub)
    System.put_env("GIT_INDEX_FILE", ".git/index")

    assert Git.hold_temporary_index(sub, held_dir) == :ok
    refute File.exists?(Path.join(held_dir, "index"))

    temporary_index(dir, "next-index-4.lock", %{"a.txt" => "rerun\n"})

    assert {:ok, [%{new_content: "rerun\n"}]} =
             Git.with_index(sub, ".git/next-index-4.lock", fn -> Git.staged_file_diffs(sub) end)
  end

  test "a new repository's own index is not mistaken for a removed one", %{held_dir: held_dir} do
    fresh = Meerkat.TestHelpers.make_git_repo("meerkat-held-index-fresh")
    on_exit(fn -> File.rm_rf!(fresh) end)
    System.put_env("GIT_INDEX_FILE", ".git/index")

    assert Git.hold_temporary_index(fresh, held_dir) == :ok
  end

  test "a named index git has already removed is an error, not an empty review",
       %{dir: dir, held_dir: held_dir} do
    System.put_env("GIT_INDEX_FILE", Path.join(dir, ".git/index.lock"))

    assert {:error, message} = Git.hold_temporary_index(dir, held_dir)
    assert message =~ "is gone"
    assert Application.fetch_env(:meerkat, :held_index) == :error
  end

  test "a copy that cannot be written is an error", %{dir: dir, held_dir: held_dir} do
    System.put_env("GIT_INDEX_FILE", temporary_index(dir, "index.lock", %{"a.txt" => "x\n"}))
    File.chmod!(held_dir, 0o500)
    on_exit(fn -> File.chmod!(held_dir, 0o700) end)

    assert {:error, message} = Git.hold_temporary_index(dir, held_dir)
    assert message =~ "couldn't keep a copy"
    assert Application.fetch_env(:meerkat, :held_index) == :error
  end

  test "when the repo path is not a repository, the named index is still copied",
       %{dir: dir, held_dir: held_dir} do
    outside =
      Path.join(System.tmp_dir!(), "meerkat-no-repo-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    System.put_env("GIT_INDEX_FILE", temporary_index(dir, "index.lock", %{"a.txt" => "x\n"}))

    Git.hold_temporary_index(outside, held_dir)

    assert File.exists?(Path.join(held_dir, "index"))
  end

  test "with no index file named there is nothing to keep", %{dir: dir, held_dir: held_dir} do
    System.delete_env("GIT_INDEX_FILE")

    Git.hold_temporary_index(dir, held_dir)

    assert File.ls!(held_dir) == []
    assert Application.fetch_env(:meerkat, :held_index) == :error
  end

  test "`with_index/3` reads the index that is named, not the copy", %{
    dir: dir,
    held_dir: held_dir
  } do
    index = temporary_index(dir, "next-index-8.lock", %{"a.txt" => "held\n"})
    System.put_env("GIT_INDEX_FILE", index)
    Git.hold_temporary_index(dir, held_dir)
    rerun = temporary_index(dir, "next-index-9.lock", %{"a.txt" => "rerun\n"})
    stage(dir, "a.txt", "own\n")

    for {name, content} <- [
          {rerun, "rerun\n"},
          {".git/next-index-9.lock", "rerun\n"},
          {"", "own\n"}
        ] do
      assert {:ok, [%{new_content: ^content}]} =
               Git.with_index(dir, name, fn -> Git.staged_file_diffs(dir) end)
    end

    assert {:ok, [%{new_content: "held\n"}]} = Git.staged_file_diffs(dir)
  end

  test "`with_index/3` nested restores the outer index when the inner one ends", %{dir: dir} do
    outer = temporary_index(dir, "next-index-1.lock", %{"a.txt" => "outer\n"})
    inner = temporary_index(dir, "next-index-2.lock", %{"a.txt" => "inner\n"})

    Git.with_index(dir, outer, fn ->
      assert {:ok, [%{new_content: "inner\n"}]} =
               Git.with_index(dir, inner, fn -> Git.staged_file_diffs(dir) end)

      assert {:ok, [%{new_content: "outer\n"}]} = Git.staged_file_diffs(dir)
    end)
  end

  test "with no copy kept, reads use the index the environment names", %{dir: dir} do
    System.put_env(
      "GIT_INDEX_FILE",
      temporary_index(dir, "next-index-3.lock", %{"a.txt" => "env\n"})
    )

    assert {:ok, [%{new_content: "env\n"}]} = Git.staged_file_diffs(dir)
  end
end
