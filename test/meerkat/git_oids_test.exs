defmodule Meerkat.GitOidsTest do
  # Real-git fixture (not async — each test owns a tmp repo and shells
  # out to `git`). Exercises the effective-OID lookups end-to-end: the
  # `git ls-files -s` / `git ls-tree HEAD` parsing, the deleted-vs-present
  # routing, and the `core.quotePath=false` raw-path matching that lets a
  # non-ASCII filename's approval survive.
  use ExUnit.Case, async: false

  alias Meerkat.Git

  setup do
    dir = Path.join(System.tmp_dir!(), "meerkat-oids-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git(dir, ["init", "-q"])
    git(dir, ["config", "user.email", "t@t.t"])
    git(dir, ["config", "user.name", "t"])
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Strip git's discovery env vars (same set as `Meerkat.Git`) before
  # shelling out. Under a git hook — e.g. the pre-push `mix test` — git
  # exports GIT_DIR / GIT_WORK_TREE pointing at meerkat's own gitdir; in
  # a linked worktree that's an ABSOLUTE path, so it overrides `cd: dir`
  # and `git init` would build the fixture repo in the wrong place.
  @git_discovery_overrides Enum.map(
                             ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
                                GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
                                GIT_NAMESPACE),
                             &{&1, nil}
                           )

  defp git(dir, args) do
    {out, code} =
      System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: @git_discovery_overrides)

    if code != 0, do: flunk("git #{Enum.join(args, " ")} failed: #{out}")
    String.trim(out)
  end

  defp seed(dir, name, content) do
    File.write!(Path.join(dir, name), content)
    git(dir, ["add", name])
  end

  defp entry(name, status), do: %{file_name: name, status: status, old_file_name: nil}

  describe "head_blob_oids_many/2" do
    test "maps each path to its HEAD pre-image blob OID", %{dir: dir} do
      seed(dir, "gone.rs", "fn gone() {}\n")
      seed(dir, "kept.rs", "fn kept() {}\n")
      git(dir, ["commit", "-qm", "seed"])

      expected = %{
        "gone.rs" => git(dir, ["rev-parse", "HEAD:gone.rs"]),
        "kept.rs" => git(dir, ["rev-parse", "HEAD:kept.rs"])
      }

      assert Git.head_blob_oids_many(dir, ["gone.rs", "kept.rs"]) == {:ok, expected}
    end

    test "a path not in HEAD is simply absent from the map", %{dir: dir} do
      seed(dir, "present.rs", "fn x() {}\n")
      git(dir, ["commit", "-qm", "seed"])

      assert {:ok, map} = Git.head_blob_oids_many(dir, ["present.rs", "never-existed.rs"])
      assert Map.keys(map) == ["present.rs"]
    end

    test "non-ASCII path matches the raw `--name-status -z` key (quotePath=false)", %{dir: dir} do
      # Without `core.quotePath=false`, ls-tree C-quotes this to
      # `"w\303\253ird.rs"`, which never matches the raw `wëird.rs`
      # that `staged_files` keys off — the deletion approval is lost.
      seed(dir, "wëird.rs", "fn w() {}\n")
      git(dir, ["commit", "-qm", "seed"])

      assert {:ok, %{"wëird.rs" => oid}} = Git.head_blob_oids_many(dir, ["wëird.rs"])
      assert oid == git(dir, ["rev-parse", "HEAD:wëird.rs"])
    end

    test "empty path list short-circuits without shelling out", %{dir: dir} do
      assert Git.head_blob_oids_many(dir, []) == {:ok, %{}}
    end
  end

  describe "effective_oids_many/2" do
    test "deletions key off HEAD pre-image, present files off the index", %{dir: dir} do
      seed(dir, "gone.rs", "fn gone() {}\n")
      seed(dir, "mod.rs", "fn mod() -> i32 { 1 }\n")
      git(dir, ["commit", "-qm", "seed"])

      git(dir, ["rm", "-q", "gone.rs"])
      File.write!(Path.join(dir, "mod.rs"), "fn mod() -> i32 { 2 }\n")
      git(dir, ["add", "mod.rs"])

      entries = [entry("gone.rs", :deleted), entry("mod.rs", :modified)]

      assert {:ok, map} = Git.effective_oids_many(dir, entries)
      # Deletion → HEAD blob (pre-image), present → index blob (post-edit).
      assert map["gone.rs"] == git(dir, ["rev-parse", "HEAD:gone.rs"])
      assert map["mod.rs"] == git(dir, ["rev-parse", ":mod.rs"])
      # The post-edit index OID differs from HEAD, so this pins the present
      # file to the index, ruling out an accidental HEAD match.
      assert map["mod.rs"] != git(dir, ["rev-parse", "HEAD:mod.rs"])
    end

    test "an all-deletions list uses HEAD pre-image OIDs", %{dir: dir} do
      seed(dir, "a.rs", "a\n")
      seed(dir, "b.rs", "b\n")
      git(dir, ["commit", "-qm", "seed"])
      git(dir, ["rm", "-q", "a.rs", "b.rs"])

      assert {:ok, map} =
               Git.effective_oids_many(dir, [entry("a.rs", :deleted), entry("b.rs", :deleted)])

      assert map == %{
               "a.rs" => git(dir, ["rev-parse", "HEAD:a.rs"]),
               "b.rs" => git(dir, ["rev-parse", "HEAD:b.rs"])
             }
    end

    test "non-ASCII deletion round-trips its pre-image OID", %{dir: dir} do
      seed(dir, "wëird.rs", "fn w() {}\n")
      git(dir, ["commit", "-qm", "seed"])
      git(dir, ["rm", "-q", "wëird.rs"])

      assert {:ok, %{"wëird.rs" => oid}} =
               Git.effective_oids_many(dir, [entry("wëird.rs", :deleted)])

      assert oid == git(dir, ["rev-parse", "HEAD:wëird.rs"])
    end
  end

  describe "git/2 fixture helper" do
    # The env strip otherwise only matters under a git hook, where GIT_DIR
    # is exported; this poisons GIT_DIR explicitly so the guard fails under
    # an ordinary `mix test` if the strip regresses.
    test "strips an inherited GIT_DIR so fixtures build in dir, not the ambient gitdir",
         %{dir: dir} do
      poison =
        Path.join(System.tmp_dir!(), "meerkat-oids-poison-#{System.unique_integer([:positive])}")

      File.mkdir_p!(poison)
      System.cmd("git", ["init", "-q", poison])
      prev = System.get_env("GIT_DIR")
      System.put_env("GIT_DIR", Path.join(poison, ".git"))

      on_exit(fn ->
        if prev, do: System.put_env("GIT_DIR", prev), else: System.delete_env("GIT_DIR")
        File.rm_rf!(poison)
      end)

      seed(dir, "x.rs", "fn x() {}\n")
      git(dir, ["commit", "-qm", "seed"])

      # The blob is in dir's HEAD only if the commit landed in dir's repo
      # rather than the poison gitdir GIT_DIR points at.
      assert {:ok, %{"x.rs" => _}} = Git.head_blob_oids_many(dir, ["x.rs"])
    end
  end
end
