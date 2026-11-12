defmodule Meerkat.GitHeldIndexTest do
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers,
    only: [blob_oid: 1, git: 2, import_commits: 2, put_env: 2, read_tree: 3]

  alias Meerkat.Git

  # What a.txt holds in the index each test reads, committed under
  # `refs/meerkat-test/<key>` so an index of it is one `read-tree`.
  @contents %{
    all: "all\n",
    by_path: "by path\n",
    first: "first\n",
    second: "second\n",
    rerun: "rerun\n",
    x: "x\n",
    held: "held\n",
    own: "own\n",
    outer: "outer\n",
    inner: "inner\n",
    env: "env\n"
  }

  # Built once. `repo` commits a.txt as "base\n"; the tests share it, each
  # naming its own index files under `.git/`, and the setup puts back
  # what a test changes. `fresh` is a new repository with no index file
  # yet; `outside` is no repository and holds an index.
  setup_all do
    template =
      Meerkat.TestHelpers.fixture_template("meerkat-held-index", fn dir ->
        repo = Path.join(dir, "repo")
        File.mkdir_p!(repo)
        git(repo, ["init", "-q", "--initial-branch=main"])

        import_commits(repo, [
          {"refs/heads/main", %{"a.txt" => "base\n"}}
          | for({key, content} <- @contents, do: {ref(key), %{"a.txt" => content}})
        ])

        git(repo, ["reset", "-q", "--hard"])
        fresh = Path.join(dir, "fresh")
        File.mkdir_p!(fresh)
        git(fresh, ["init", "-q"])
        File.mkdir_p!(Path.join(dir, "outside"))
        read_tree(repo, ref(:x), Path.join(dir, "outside/index.lock"))
      end)

    {:ok,
     dir: Path.join(template, "repo"),
     fresh: Path.join(template, "fresh"),
     outside: Path.join(template, "outside")}
  end

  setup %{dir: dir} do
    held_dir = Path.join(dir, ".git/run")
    File.mkdir_p!(held_dir)

    on_exit(fn ->
      Application.delete_env(:meerkat, :held_index)
      File.rm_rf!(held_dir)
      Enum.each(Path.wildcard(Path.join(dir, ".git/*.lock")), &File.rm!/1)
      read_tree(dir, "HEAD", nil)
    end)

    {:ok, held_dir: held_dir}
  end

  defp ref(key), do: "refs/meerkat-test/#{key}"

  # An index file `.git/<name>` holding a.txt as `@contents[key]`.
  defp index(dir, name, key) do
    path = Path.join(dir, ".git/" <> name)
    read_tree(dir, ref(key), path)
    path
  end

  # Stages a.txt as `@contents[key]` in the repository's own index.
  defp stage(dir, key), do: read_tree(dir, ref(key), nil)

  test "reads of a temporary index still see it once git has deleted it",
       %{dir: dir, held_dir: held_dir} do
    index = index(dir, "index.lock", :all)
    put_env("GIT_INDEX_FILE", index)

    Git.hold_temporary_index(dir, held_dir)
    File.rm!(index)

    assert {:ok, [%{file_name: "a.txt", new_content: "all\n"} = file]} =
             Git.staged_file_diffs(dir)

    assert {:ok, file.effective_oid} == Git.fetch_staged_blob_oid(dir, "a.txt")
    assert file.effective_oid == blob_oid("all\n")
  end

  test "a restarted BEAM finds the copy the one before it took", %{dir: dir, held_dir: held_dir} do
    index = index(dir, "next-index-7.lock", :by_path)
    put_env("GIT_INDEX_FILE", index)
    Git.hold_temporary_index(dir, held_dir)
    File.rm!(index)
    Application.delete_env(:meerkat, :held_index)

    Git.hold_temporary_index(dir, held_dir)

    assert {:ok, [%{file_name: "a.txt", new_content: "by path\n"}]} = Git.staged_file_diffs(dir)
  end

  test "the repository's own index is read where it lives, however its path is spelled",
       %{dir: dir, held_dir: held_dir} do
    stage(dir, :first)

    for name <- [".git/index", Path.join(dir, ".git/index"), Path.join(dir, ".git/../.git/index")] do
      put_env("GIT_INDEX_FILE", name)
      Git.hold_temporary_index(dir, held_dir)
    end

    stage(dir, :second)

    refute File.exists?(Path.join(held_dir, "index"))
    assert {:ok, [%{new_content: "second\n"}]} = Git.staged_file_diffs(dir)
  end

  test "a relative name is taken from the top of the work tree, as git takes it",
       %{dir: dir, held_dir: held_dir} do
    sub = Path.join(dir, "sub")
    File.mkdir_p!(sub)
    on_exit(fn -> File.rm_rf!(sub) end)
    put_env("GIT_INDEX_FILE", ".git/index")
    # Trace lines on stderr must not end up in the work-tree path.
    put_env("GIT_TRACE", "1")

    assert Git.hold_temporary_index(sub, held_dir) == :ok
    refute File.exists?(Path.join(held_dir, "index"))
    put_env("GIT_TRACE", nil)

    index(dir, "next-index-4.lock", :rerun)

    assert {:ok, [%{new_content: "rerun\n"}]} =
             Git.with_index(sub, ".git/next-index-4.lock", fn -> Git.staged_file_diffs(sub) end)
  end

  test "a new repository's own index is not mistaken for a removed one", %{
    fresh: fresh,
    held_dir: held_dir
  } do
    put_env("GIT_INDEX_FILE", ".git/index")

    assert Git.hold_temporary_index(fresh, held_dir) == :ok
  end

  test "a named index git has already removed is an error, not an empty review",
       %{dir: dir, held_dir: held_dir} do
    put_env("GIT_INDEX_FILE", Path.join(dir, ".git/index.lock"))

    assert {:error, message} = Git.hold_temporary_index(dir, held_dir)
    assert message =~ "no longer exists"
    assert Application.fetch_env(:meerkat, :held_index) == :error
  end

  test "a copy that cannot be written is an error", %{dir: dir} do
    put_env("GIT_INDEX_FILE", index(dir, "index.lock", :x))

    # A file where the copy's directory should be, which even root cannot write under.
    assert {:error, message} = Git.hold_temporary_index(dir, Path.join(dir, "a.txt"))
    assert message =~ "couldn't keep a copy"
    assert Application.fetch_env(:meerkat, :held_index) == :error
  end

  test "when the repo path is not a repository, the named index is still copied",
       %{outside: outside, held_dir: held_dir} do
    # Relative, so it is taken from the repo path: there is no work tree.
    put_env("GIT_INDEX_FILE", "index.lock")

    assert Git.hold_temporary_index(outside, held_dir) == :ok

    assert File.exists?(Path.join(held_dir, "index"))
  end

  test "with no index file named there is nothing to keep", %{dir: dir, held_dir: held_dir} do
    put_env("GIT_INDEX_FILE", nil)

    Git.hold_temporary_index(dir, held_dir)

    assert File.ls!(held_dir) == []
    assert Application.fetch_env(:meerkat, :held_index) == :error
  end

  test "`with_index/3` reads the index that is named, not the copy", %{
    dir: dir,
    held_dir: held_dir
  } do
    index = index(dir, "next-index-8.lock", :held)
    put_env("GIT_INDEX_FILE", index)
    Git.hold_temporary_index(dir, held_dir)
    rerun = index(dir, "next-index-9.lock", :rerun)
    stage(dir, :own)

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
    outer = index(dir, "next-index-1.lock", :outer)
    inner = index(dir, "next-index-2.lock", :inner)

    Git.with_index(dir, outer, fn ->
      assert {:ok, [%{new_content: "inner\n"}]} =
               Git.with_index(dir, inner, fn -> Git.staged_file_diffs(dir) end)

      assert {:ok, [%{new_content: "outer\n"}]} = Git.staged_file_diffs(dir)
    end)
  end

  test "with no copy kept, reads use the index the environment names", %{dir: dir} do
    put_env("GIT_INDEX_FILE", index(dir, "next-index-3.lock", :env))

    assert {:ok, [%{new_content: "env\n"}]} = Git.staged_file_diffs(dir)
  end
end
