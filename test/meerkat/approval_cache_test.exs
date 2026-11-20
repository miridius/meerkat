defmodule Meerkat.ApprovalCacheTest do
  # Not async: a path_for/1 test sets the global :approval_cache_path.
  use Meerkat.Case, async: false

  import ExUnit.CaptureIO, only: [with_io: 2]

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

  # A repo the path_for/1 tests only read.
  setup_all do
    repo =
      Meerkat.TestHelpers.fixture_template("meerkat-approval-path", fn dir ->
        Meerkat.TestHelpers.git(dir, ["init", "-q"])
      end)

    {:ok, repo: repo}
  end

  describe "path_for/1" do
    test "is approved.json in the shared gitdir", %{repo: repo} do
      path = ApprovalCache.path_for(repo)
      assert path == Path.join([repo, ".git", "meerkat-precommit", "approved.json"])
    end

    test "outside a repo is nil" do
      dir = Meerkat.TestHelpers.tmp_path("meerkat-approval-nogit")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      assert ApprovalCache.path_for(dir) == nil
    end

    test "is the cached :approval_cache_path when set, ahead of git and without it", %{
      repo: repo
    } do
      cached = Path.join(repo, "cached.json")
      Application.put_env(:meerkat, :approval_cache_path, cached)
      on_exit(fn -> Application.delete_env(:meerkat, :approval_cache_path) end)
      assert ApprovalCache.path_for(repo) == cached
      Meerkat.TestHelpers.stub_git(fn argv -> flunk("ran #{inspect(argv)}") end)
      assert ApprovalCache.path_for(repo) == cached
    end

    test "is cached by Meerkat.CLI for a review, with its meerkat_dir", %{repo: repo} do
      path = ApprovalCache.path_for(repo)
      meerkat_dir = Meerkat.Git.meerkat_dir(repo)

      on_exit(fn ->
        Application.delete_env(:meerkat, :approval_cache_path)
        Application.delete_env(:meerkat, :meerkat_dir)
      end)

      assert Meerkat.CLI.cache_review_paths(repo) == meerkat_dir
      assert Application.get_env(:meerkat, :meerkat_dir) == meerkat_dir
      assert Application.get_env(:meerkat, :approval_cache_path) == path
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

  describe "key_for/2 and prune_for/1 with real git" do
    import Meerkat.TestHelpers, only: [commit: 2, git: 2, make_git_repo: 1]

    test "a detached HEAD keys by its worktree's gitdir name, and prune_for keeps live " <>
           "branches and worktrees and drops the rest" do
      dir = make_git_repo("meerkat-approval-keys")
      linked = dir <> "-linked"
      on_exit(fn -> Enum.each([dir, linked], &File.rm_rf!/1) end)
      git(dir, ["symbolic-ref", "HEAD", "refs/heads/main"])
      commit(dir, "seed")
      git(dir, ["worktree", "add", "-q", "-b", "side", linked])

      assert ApprovalCache.key_for(dir, nil) == "detached HEAD (.git)"
      linked_key = "detached HEAD (#{Path.basename(linked)})"
      assert ApprovalCache.key_for(linked, nil) == linked_key
      live = ["detached HEAD (.git)", linked_key, "main", "side"]
      seed_keys(dir, live ++ ["gone", "detached HEAD (gone)"])

      prune!(dir)
      assert keys(dir) == Enum.sort(live)

      seed_keys(dir, ["gone", "detached HEAD (gone)"])
      prune!(linked)
      assert keys(dir) == Enum.sort(live)

      git(dir, ["worktree", "remove", linked])
      prune!(dir)
      assert keys(dir) == ["detached HEAD (.git)", "main", "side"]
    end

    test "outside a repo, a detached HEAD has no key and prune_for does nothing" do
      dir = Meerkat.TestHelpers.tmp_path("meerkat-approval-nogit")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert ApprovalCache.key_for(dir, nil) == nil
      assert ApprovalCache.prune_for(dir) == %{}
    end
  end

  describe "key_for/2 and prune_for/1" do
    # A common dir laid out as git lays one out. The stand-in for git
    # answers `--git-dir` and `--git-common-dir` with it and lists `main`
    # as the only branch; any other git call fails the test.
    setup do
      dir = Meerkat.TestHelpers.tmp_path("meerkat-approval-keys")
      common = Path.join(dir, "repo/.git")
      File.mkdir_p!(common)
      on_exit(fn -> File.rm_rf!(dir) end)

      Meerkat.TestHelpers.stub_git(fn argv ->
        cond do
          "--git-common-dir" in argv -> {common <> "\n", 0}
          "--git-dir" in argv -> {common <> "\n", 0}
          "for-each-ref" in argv -> {"main\n", 0}
        end
      end)

      {:ok, dir: dir, common: common}
    end

    # A linked worktree `name`, whose gitdir file names `target`: its
    # `.git` file at `dir/<name>`, which `opts[:live]` creates.
    defp linked(%{dir: dir, common: common}, name, opts \\ []) do
      gitdir = Path.join([common, "worktrees", name])
      File.mkdir_p!(gitdir)
      worktree = Path.join(dir, name)
      target = Path.join(worktree, ".git")

      if opts[:live] do
        File.mkdir_p!(worktree)
        File.write!(target, "gitdir: #{gitdir}\n")
      end

      if opts[:locked], do: File.write!(Path.join(gitdir, "locked"), "")
      if opts[:relative], do: write_gitdir(gitdir, Path.relative_to(target, gitdir, force: true))
      if !opts[:relative] and !opts[:no_gitdir], do: write_gitdir(gitdir, target)
      "detached HEAD (#{name})"
    end

    defp write_gitdir(gitdir, target),
      do: File.write!(Path.join(gitdir, "gitdir"), target <> "\n")

    test "a branch is its own key", %{dir: dir} do
      assert ApprovalCache.key_for(dir, "feature/x") == "feature/x"
    end

    test "a detached HEAD keys by its gitdir's name", %{dir: dir} do
      assert ApprovalCache.key_for(dir, nil) == "detached HEAD (.git)"
    end

    test "prune_for with no linked worktree keeps the main worktree's key", %{dir: dir} do
      seed_keys(dir, ["main", "gone", "detached HEAD (.git)", "detached HEAD (gone)"])

      prune!(dir)
      assert keys(dir) == ["detached HEAD (.git)", "main"]
    end

    test "prune_for drops a linked worktree deleted without git", %{dir: dir} = ctx do
      linked_key = linked(ctx, "linked")
      seed_keys(dir, ["main", linked_key])

      prune!(dir)
      assert keys(dir) == ["main"]
    end

    test "prune_for keeps a locked worktree whose folder is gone", %{dir: dir} = ctx do
      linked_key = linked(ctx, "linked", locked: true)
      seed_keys(dir, [linked_key])

      prune!(dir)
      assert keys(dir) == [linked_key]
    end

    test "prune_for reads a relative gitdir file, and drops a worktree without one",
         %{dir: dir} = ctx do
      linked_key = linked(ctx, "linked", live: true, relative: true)
      other_key = linked(ctx, "other", live: true, no_gitdir: true)
      seed_keys(dir, ["main", linked_key, other_key])

      prune!(dir)
      assert keys(dir) == [linked_key, "main"]
    end

    test "prune_for keeps a worktree whose gitdir file can't be read", %{dir: dir} = ctx do
      linked_key = linked(ctx, "linked")
      seed_keys(dir, [linked_key])
      file = Path.join([ctx.common, "worktrees", "linked", "gitdir"])
      File.chmod!(file, 0o000)
      on_exit(fn -> File.chmod(file, 0o644) end)

      prune!(dir)
      assert keys(dir) == [linked_key]
    end

    test "prune_for prunes nothing when the worktree list can't be read", %{dir: dir} = ctx do
      linked(ctx, "linked", live: true)
      seed_keys(dir, ["gone"])
      worktrees = Path.join(ctx.common, "worktrees")
      File.chmod!(worktrees, 0o000)
      on_exit(fn -> File.chmod(worktrees, 0o755) end)

      prune!(dir)
      assert keys(dir) == ["gone"]
    end
  end

  # The cache prune_for returns is the one it left on disk.
  defp prune!(dir) do
    pruned = ApprovalCache.prune_for(dir)
    assert pruned == ApprovalCache.load_for(dir)
  end

  defp keys(dir), do: dir |> ApprovalCache.load_for() |> Map.keys() |> Enum.sort()

  defp seed_keys(dir, keys) do
    approve_all = fn cache ->
      Enum.reduce(keys, cache, &ApprovalCache.approve(&2, &1, "f", "1"))
    end

    {:ok, _} = ApprovalCache.modify(ApprovalCache.path_for(dir), approve_all)
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

    test "saves indented JSON a person can read", %{dir: dir} do
      path = Path.join(dir, "approved.json")
      :ok = ApprovalCache.save(ApprovalCache.approve(%{}, "main", "a.rs", "1"), path)

      assert File.read!(path) =~ ~s(\n  "version": 2)
    end

    test "a failed save returns the error and warns", %{dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "file"), "")
      path = Path.join([dir, "file", "approved.json"])

      {result, stderr} = with_io(:stderr, fn -> ApprovalCache.save(%{}, path) end)

      assert {:error, :enotdir} = result

      assert stderr =~
               "meerkat: warning — couldn't save approval cache to #{path}: :enotdir"
    end

    test "missing file loads as empty without a warning", %{dir: dir} do
      path = Path.join(dir, "nope.json")

      {result, stderr} = with_io(:stderr, fn -> ApprovalCache.load(path) end)

      assert result == %{}
      refute stderr =~ path
    end

    test "an unreadable file loads as empty and warns", %{dir: dir} do
      File.mkdir_p!(dir)

      {result, stderr} = with_io(:stderr, fn -> ApprovalCache.load(dir) end)

      assert result == %{}
      assert stderr =~ "meerkat: warning — couldn't read approval cache at #{dir}: :eisdir"
    end

    for {label, body, reason} <- [
          {"wrong version", ~s({"version":1,"branches":{"main":{"x":["1"]}}}),
           "schema version mismatch (got 1, want 2)"},
          {"no version key", ~s({"branches":{}}), "missing version/branches keys"}
        ] do
      test "a file with #{label} loads as empty and is quarantined", %{dir: dir} do
        path = Path.join(dir, "approved.json")
        File.mkdir_p!(dir)
        File.write!(path, unquote(body))

        {result, stderr} = with_io(:stderr, fn -> ApprovalCache.load(path) end)

        assert result == %{}
        assert_quarantined(path)

        assert stderr =~
                 ~r/approval cache at #{Regex.escape(path)} unusable \(#{Regex.escape(unquote(reason))}\); moved to \S+\. Starting from an empty cache\.\n\z/
      end
    end

    test "a file whose branches are not an object loads as empty and is quarantined",
         %{dir: dir} do
      path = Path.join(dir, "approved.json")
      File.mkdir_p!(dir)
      File.write!(path, ~s({"version":2,"branches":["main"]}))

      {result, _stderr} = with_io(:stderr, fn -> ApprovalCache.load(path) end)

      assert result == %{}
      assert_quarantined(path)
    end

    test "malformed JSON loads as empty and is quarantined", %{dir: dir} do
      path = Path.join(dir, "approved.json")
      File.mkdir_p!(dir)
      File.write!(path, "not json at all")
      {:error, err} = Jason.decode("not json at all")

      {result, stderr} = with_io(:stderr, fn -> ApprovalCache.load(path) end)

      assert result == %{}
      assert_quarantined(path)
      assert stderr =~ "unusable (JSON parse failed: #{Exception.message(err)}); moved to"
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

    test "rejects a mutator that does not take the cache, touching nothing", %{path: path} do
      assert_raise FunctionClauseError, fn -> ApprovalCache.modify(path, fn -> %{} end) end
      refute File.exists?(Path.dirname(path))
    end

    test "waits for a lock another writer releases, without forcing it", %{path: path} do
      lock_dir = path <> ".lock.d"
      File.mkdir_p!(lock_dir)

      releaser =
        Task.async(fn ->
          Process.sleep(100)
          File.rmdir!(lock_dir)
        end)

      {result, stderr} =
        with_io(:stderr, fn ->
          ApprovalCache.modify(path, &ApprovalCache.approve(&1, "main", "f.rs", "1"), 5_000)
        end)

      Task.await(releaser)
      assert {:ok, %{"main" => %{"f.rs" => ["1"]}}} = result
      refute stderr =~ lock_dir
      refute File.exists?(lock_dir)
    end

    test "force-takes a lock held past the wait and still writes", %{path: path} do
      lock_dir = path <> ".lock.d"
      File.mkdir_p!(lock_dir)

      {result, stderr} =
        with_io(:stderr, fn ->
          ApprovalCache.modify(path, &ApprovalCache.approve(&1, "main", "f.rs", "1"), 50)
        end)

      assert {:ok, _} = result
      assert ApprovalCache.approved?(ApprovalCache.load(path), "main", "f.rs", "1")

      assert stderr ==
               "meerkat: warning — approval-cache lock at #{lock_dir} held for >50 ms. " <>
                 "Likely stale (killed meerkat). Forcing take.\n"

      refute File.exists?(lock_dir)
    end

    test "gives up when a lock it force-takes cannot be removed", %{path: path} do
      lock_dir = path <> ".lock.d"
      File.mkdir_p!(lock_dir)
      File.write!(Path.join(lock_dir, "stray"), "")

      {result, _stderr} =
        with_io(:stderr, fn ->
          ApprovalCache.modify(path, &ApprovalCache.approve(&1, "main", "f.rs", "1"), 50)
        end)

      assert result == {:error, {:lock_failed, :eexist}}
      refute File.exists?(path)
    end

    test "sleeps between tries while it waits for a lock", %{path: path} do
      lock_dir = path <> ".lock.d"
      File.mkdir_p!(lock_dir)
      on_exit(fn -> File.rm_rf(lock_dir) end)

      waiter =
        Task.async(fn ->
          with_io(:stderr, fn ->
            ApprovalCache.modify(path, &ApprovalCache.approve(&1, "main", "f.rs", "1"), 5_000)
          end)
        end)

      assert Meerkat.TestHelpers.eventually(fn ->
               Process.info(waiter.pid, :current_function) ==
                 {:current_function, {Process, :sleep, 1}}
             end)

      File.rmdir!(lock_dir)
      assert {{:ok, _}, ""} = Task.await(waiter, 10_000)
    end

    test "skips the write when the lock cannot be created", %{path: path} do
      dir = Path.dirname(path)
      lock_dir = path <> ".lock.d"
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o555)
      on_exit(fn -> File.chmod(dir, 0o755) end)

      {result, stderr} =
        with_io(:stderr, fn -> ApprovalCache.modify(path, &Map.put(&1, "main", %{})) end)

      assert result == {:error, {:lock_failed, :eacces}}

      assert stderr ==
               "meerkat: warning — couldn't acquire approval-cache lock at #{lock_dir}: " <>
                 ":eacces. Skipping cache write to avoid clobbering concurrent worktrees.\n"

      refute File.exists?(path)
    end

    test "returns the error when the cache directory cannot be created", %{path: path} do
      File.mkdir_p!(Path.dirname(Path.dirname(path)))
      File.write!(Path.dirname(path), "a file, not a directory")

      {result, stderr} =
        with_io(:stderr, fn -> ApprovalCache.modify(path, &Map.put(&1, "main", %{})) end)

      assert result == {:error, :enotdir}

      assert stderr ==
               "meerkat: warning — couldn't create approval-cache directory at " <>
                 "#{Path.dirname(path)}: :enotdir. Approval ticks won't persist this session.\n"
    end

    test "returns a failed save's error and releases the lock", %{path: path} do
      File.mkdir_p!(path)

      {result, _stderr} =
        with_io(:stderr, fn -> ApprovalCache.modify(path, &Map.put(&1, "main", %{})) end)

      assert {:error, _} = result
      refute File.exists?(path <> ".lock.d")
    end

    test "a lock another writer already removed is released without a warning",
         %{path: path} do
      lock_dir = path <> ".lock.d"

      {result, stderr} =
        with_io(:stderr, fn ->
          ApprovalCache.modify(path, fn cache ->
            File.rmdir!(lock_dir)
            cache
          end)
        end)

      assert {:ok, %{}} = result
      refute stderr =~ lock_dir
    end

    test "warns when the lock cannot be released", %{path: path} do
      lock_dir = path <> ".lock.d"

      {result, stderr} =
        with_io(:stderr, fn ->
          ApprovalCache.modify(path, fn cache ->
            File.write!(Path.join(lock_dir, "stray"), "")
            cache
          end)
        end)

      assert {:ok, %{}} = result

      assert stderr =~
               ~r/meerkat: warning — couldn't release approval-cache lock at #{Regex.escape(lock_dir)}: :\w+\. Next concurrent writer will force-take after 10s\.\n\z/

      assert File.dir?(lock_dir)
    end
  end

  defp assert_quarantined(path) do
    refute File.exists?(path)
    base = Path.basename(path) <> ".corrupt."
    assert path |> Path.dirname() |> File.ls!() |> Enum.any?(&String.starts_with?(&1, base))
  end
end
