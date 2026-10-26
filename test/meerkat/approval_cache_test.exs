defmodule Meerkat.ApprovalCacheTest do
  use ExUnit.Case, async: true

  alias Meerkat.ApprovalCache

  describe "approve / approved? / unapprove" do
    test "approve adds (branch, file, oid) and approved? finds it" do
      cache =
        %{}
        |> ApprovalCache.approve("main", "src/main.rs", "abc123")

      assert ApprovalCache.approved?(cache, "main", "src/main.rs", "abc123")
      refute ApprovalCache.approved?(cache, "main", "src/main.rs", "def456")
      refute ApprovalCache.approved?(cache, "other", "src/main.rs", "abc123")
    end

    test "approve is idempotent and accumulates OIDs across content flip-flops" do
      cache =
        %{}
        |> ApprovalCache.approve("main", "a.rs", "v1")
        |> ApprovalCache.approve("main", "a.rs", "v2")
        |> ApprovalCache.approve("main", "a.rs", "v1")

      assert ApprovalCache.approved?(cache, "main", "a.rs", "v1")
      assert ApprovalCache.approved?(cache, "main", "a.rs", "v2")
      assert get_in(cache, ["main", "a.rs"]) |> length() == 2
    end

    test "approve prepends OIDs newest-first" do
      cache =
        %{}
        |> ApprovalCache.approve("main", "a.rs", "v1")
        |> ApprovalCache.approve("main", "a.rs", "v2")
        |> ApprovalCache.approve("main", "a.rs", "v3")

      assert get_in(cache, ["main", "a.rs"]) == ["v3", "v2", "v1"]
    end

    test "unapprove drops the file entry; empty branches are dropped too" do
      cache =
        %{}
        |> ApprovalCache.approve("main", "a", "1")
        |> ApprovalCache.approve("main", "b", "2")

      cache = ApprovalCache.unapprove(cache, "main", "a")
      assert cache == %{"main" => %{"b" => ["2"]}}

      cache = ApprovalCache.unapprove(cache, "main", "b")
      assert cache == %{}
    end

    test "unapprove on a missing key is a no-op" do
      assert ApprovalCache.unapprove(%{}, "main", "missing") == %{}
    end
  end

  describe "prune/2" do
    test "drops branch sub-trees for unknown branches" do
      cache =
        %{}
        |> ApprovalCache.approve("main", "a", "1")
        |> ApprovalCache.approve("feature", "b", "2")
        |> ApprovalCache.approve("stale", "c", "3")

      pruned = ApprovalCache.prune(cache, MapSet.new(["main", "feature"]))

      assert Map.has_key?(pruned, "main")
      assert Map.has_key?(pruned, "feature")
      refute Map.has_key?(pruned, "stale")
    end

    test "pruning against an empty known-branch set drops everything" do
      cache =
        %{}
        |> ApprovalCache.approve("main", "a.rs", "1")
        |> ApprovalCache.approve("feature", "b.rs", "2")

      assert ApprovalCache.prune(cache, MapSet.new()) == %{}
    end
  end

  describe "key_for/2 and prune_for/1 (real git fixture)" do
    import Meerkat.TestHelpers, only: [git: 2, make_git_repo: 1]

    setup do
      dir = make_git_repo("meerkat-approval-keys")
      linked = dir <> "-linked"
      on_exit(fn -> Enum.each([dir, linked], &File.rm_rf!/1) end)
      git(dir, ["symbolic-ref", "HEAD", "refs/heads/main"])

      git(dir, [
        "-c",
        "user.email=t@t",
        "-c",
        "user.name=t",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "seed"
      ])

      {:ok, dir: dir, linked: linked}
    end

    test "a branch is its own key", %{dir: dir} do
      assert ApprovalCache.key_for(dir, "feature/x") == "feature/x"
    end

    test "a detached HEAD keys by its worktree's gitdir name", %{dir: dir, linked: linked} do
      git(dir, ["worktree", "add", "-q", "--detach", linked])

      assert ApprovalCache.key_for(dir, nil) == "detached HEAD (.git)"
      assert ApprovalCache.key_for(linked, nil) == "detached HEAD (#{Path.basename(linked)})"
    end

    test "a detached HEAD outside a repo has no key", %{linked: not_a_repo} do
      File.mkdir_p!(not_a_repo)
      assert ApprovalCache.key_for(not_a_repo, nil) == nil
    end

    test "the cache lives in the git common dir", %{dir: dir} do
      assert ApprovalCache.path_for(dir) ==
               Path.join([dir, ".git", "meerkat-precommit", "approved.json"])
    end

    test "prune_for with no linked worktree keeps the main worktree's key", %{dir: dir} do
      seed_keys(dir, ["main", "gone", "detached HEAD (.git)", "detached HEAD (gone)"])

      assert ApprovalCache.prune_for(dir) == :ok
      assert keys(dir) == ["detached HEAD (.git)", "main"]
    end

    test "prune_for keeps live branches and worktrees and drops the rest", %{
      dir: dir,
      linked: linked
    } do
      git(dir, ["worktree", "add", "-q", "-b", "side", linked])
      linked_key = "detached HEAD (#{Path.basename(linked)})"
      live = ["detached HEAD (.git)", linked_key, "main", "side"]
      seed_keys(dir, live ++ ["gone", "detached HEAD (gone)"])

      assert ApprovalCache.prune_for(dir) == :ok
      assert keys(dir) == Enum.sort(live)

      git(dir, ["worktree", "remove", linked])
      :ok = ApprovalCache.prune_for(dir)
      assert keys(dir) == ["detached HEAD (.git)", "main", "side"]
    end

    test "prune_for drops a linked worktree deleted without git", %{dir: dir, linked: linked} do
      git(dir, ["worktree", "add", "-q", "--detach", linked])
      linked_key = "detached HEAD (#{Path.basename(linked)})"
      seed_keys(dir, ["main", linked_key])
      File.rm_rf!(linked)

      :ok = ApprovalCache.prune_for(dir)
      assert keys(dir) == ["main"]
    end

    test "prune_for reads a relative gitdir file, and drops a worktree without one", %{
      dir: dir,
      linked: linked
    } do
      other = linked <> "2"
      on_exit(fn -> File.rm_rf!(other) end)
      git(dir, ["worktree", "add", "-q", "--detach", linked])
      git(dir, ["worktree", "add", "-q", "--detach", other])
      gitdir = Path.join([dir, ".git", "worktrees", Path.basename(linked)])
      relative = Path.relative_to(Path.join(linked, ".git"), gitdir, force: true)
      File.write!(Path.join(gitdir, "gitdir"), relative <> "\n")
      File.rm!(Path.join([dir, ".git", "worktrees", Path.basename(other), "gitdir"]))
      linked_key = "detached HEAD (#{Path.basename(linked)})"
      seed_keys(dir, ["main", linked_key, "detached HEAD (#{Path.basename(other)})"])

      :ok = ApprovalCache.prune_for(dir)
      assert keys(dir) == [linked_key, "main"]
    end

    test "prune_for keeps a worktree whose gitdir file can't be read", %{
      dir: dir,
      linked: linked
    } do
      git(dir, ["worktree", "add", "-q", "--detach", linked])
      linked_key = "detached HEAD (#{Path.basename(linked)})"
      seed_keys(dir, [linked_key])
      file = Path.join([dir, ".git", "worktrees", Path.basename(linked), "gitdir"])
      File.chmod!(file, 0o000)
      on_exit(fn -> File.chmod(file, 0o644) end)

      :ok = ApprovalCache.prune_for(dir)
      assert keys(dir) == [linked_key]
    end

    test "prune_for prunes nothing when the worktree list can't be read", %{
      dir: dir,
      linked: linked
    } do
      git(dir, ["worktree", "add", "-q", "--detach", linked])
      seed_keys(dir, ["gone"])
      worktrees = Path.join([dir, ".git", "worktrees"])
      File.chmod!(worktrees, 0o000)
      on_exit(fn -> File.chmod(worktrees, 0o755) end)

      assert ApprovalCache.prune_for(dir) == :ok
      assert keys(dir) == ["gone"]
    end

    test "prune_for outside a repo does nothing", %{linked: not_a_repo} do
      File.mkdir_p!(not_a_repo)
      assert ApprovalCache.prune_for(not_a_repo) == :ok
    end

    defp keys(dir), do: dir |> ApprovalCache.load_for() |> Map.keys() |> Enum.sort()

    defp seed_keys(dir, keys) do
      approve_all = fn cache ->
        Enum.reduce(keys, cache, &ApprovalCache.approve(&2, &1, "f", "1"))
      end

      {:ok, _} = ApprovalCache.modify(ApprovalCache.path_for(dir), approve_all)
    end
  end

  describe "save / load round-trip" do
    setup do
      tmp =
        Meerkat.TestHelpers.tmp_path("meerkat-approval")

      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, dir: tmp}
    end

    test "save then load returns the same cache", %{dir: dir} do
      path = Path.join(dir, "approved.json")

      cache =
        %{}
        |> ApprovalCache.approve("main", "src/main.rs", "abc")
        |> ApprovalCache.approve("main", "NOTES.md", "def")
        |> ApprovalCache.approve("feature", "x.rs", "111")

      assert :ok = ApprovalCache.save(cache, path)
      loaded = ApprovalCache.load(path)

      assert ApprovalCache.approved?(loaded, "main", "src/main.rs", "abc")
      assert ApprovalCache.approved?(loaded, "main", "NOTES.md", "def")
      assert ApprovalCache.approved?(loaded, "feature", "x.rs", "111")
    end

    test "missing file loads as empty", %{dir: dir} do
      assert ApprovalCache.load(Path.join(dir, "nope.json")) == %{}
    end

    test "wrong version loads as empty", %{dir: dir} do
      path = Path.join(dir, "approved.json")
      File.mkdir_p!(dir)
      File.write!(path, ~s({"version":1,"branches":{"main":{"x":["1"]}}}))

      assert ApprovalCache.load(path) == %{}
    end

    test "malformed JSON loads as empty", %{dir: dir} do
      path = Path.join(dir, "approved.json")
      File.mkdir_p!(dir)
      File.write!(path, "not json at all")

      assert ApprovalCache.load(path) == %{}
    end
  end

  describe "modify/2" do
    setup do
      tmp =
        Meerkat.TestHelpers.tmp_path("meerkat-approval")

      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, path: Path.join(tmp, "approved.json")}
    end

    test "applies mutator and persists", %{path: path} do
      assert {:ok, cache} =
               ApprovalCache.modify(path, &ApprovalCache.approve(&1, "main", "f.rs", "1"))

      assert ApprovalCache.approved?(cache, "main", "f.rs", "1")
      assert ApprovalCache.approved?(ApprovalCache.load(path), "main", "f.rs", "1")
    end
  end
end
