defmodule Meerkat.GitOidsTest do
  # Exercises the effective-OID lookups end-to-end against one real repo,
  # built once: the `git ls-files -s` / `git ls-tree HEAD` parsing, the
  # deleted-vs-present routing, and the `core.quotePath=false` raw-path
  # matching that lets a non-ASCII filename's approval survive.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers,
    only: [blob_oid: 1, git: 2, import_commits: 2, read_tree: 3, stub_git: 2]

  alias Meerkat.Git

  @head %{
    "gone.rs" => "fn gone() {}\n",
    "kept.rs" => "fn kept() {}\n",
    "mod.rs" => "fn mod() -> i32 { 1 }\n",
    "a.rs" => "a\n",
    "b.rs" => "b\n",
    "wëird.rs" => "fn w() {}\n"
  }

  # The index deletes gone.rs, a.rs, b.rs and wëird.rs, edits mod.rs and
  # adds two files.
  @index %{
    "kept.rs" => "fn kept() {}\n",
    "mod.rs" => "fn mod() -> i32 { 2 }\n",
    "staged.rs" => "fn s() {}\n",
    ":x.rs" => "fn colon() {}\n"
  }

  setup_all do
    repo =
      Meerkat.TestHelpers.fixture_template("meerkat-oids", fn dir ->
        git(dir, ["init", "-q", "--initial-branch=main"])

        import_commits(dir, [
          {"refs/heads/main", @head},
          {"refs/meerkat-test/index", @index}
        ])

        read_tree(dir, "refs/meerkat-test/index", nil)
      end)

    {:ok, dir: repo}
  end

  defp entry(name, status), do: %{file_name: name, status: status, old_file_name: nil}

  describe "fetch_staged_blob_oid/2" do
    test "a staged path yields its index blob OID", %{dir: dir} do
      assert Git.fetch_staged_blob_oid(dir, "staged.rs") == {:ok, blob_oid(@index["staged.rs"])}
    end

    test "a path not in the index is :not_staged", %{dir: dir} do
      assert Git.fetch_staged_blob_oid(dir, "never-added.rs") == :not_staged
    end

    test "a staged path git would read as pathspec magic yields its blob OID", %{dir: dir} do
      assert Git.fetch_staged_blob_oid(dir, ":x.rs") == {:ok, blob_oid(@index[":x.rs"])}
    end
  end

  describe "head_blob_oids_many/2" do
    test "maps each path to its HEAD pre-image blob OID", %{dir: dir} do
      expected = %{
        "gone.rs" => blob_oid(@head["gone.rs"]),
        "kept.rs" => blob_oid(@head["kept.rs"])
      }

      assert Git.head_blob_oids_many(dir, ["gone.rs", "kept.rs"]) == {:ok, expected}
    end

    test "a path not in HEAD is simply absent from the map", %{dir: dir} do
      assert {:ok, map} = Git.head_blob_oids_many(dir, ["kept.rs", "never-existed.rs"])
      assert Map.keys(map) == ["kept.rs"]
    end

    test "non-ASCII path matches the raw `--name-status -z` key (quotePath=false)", %{dir: dir} do
      # Without `core.quotePath=false`, ls-tree C-quotes this to
      # `"w\303\253ird.rs"`, which never matches the raw `wëird.rs`
      # that `staged_files` keys off — the deletion approval is lost.
      assert Git.head_blob_oids_many(dir, ["wëird.rs"]) ==
               {:ok, %{"wëird.rs" => blob_oid(@head["wëird.rs"])}}
    end

    test "empty path list short-circuits without shelling out", %{dir: dir} do
      stub_git("ls-tree", fn argv -> flunk("ran #{inspect(argv)}") end)
      assert Git.head_blob_oids_many(dir, []) == {:ok, %{}}
    end

    test "a repo with no commits yet is an error, since there is no HEAD tree", %{dir: dir} do
      # git's answer in a repo with no commit.
      stub_git("ls-tree", {"fatal: Not a valid object name HEAD\n", 128})

      {result, _stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Git.head_blob_oids_many(dir, ["a.rs"]) end)

      assert result ==
               {:error,
                "couldn't compute batched HEAD-blob OIDs (git --literal-pathspecs -c " <>
                  "core.quotePath=false ls-tree HEAD -- a.rs exited 128: fatal: Not a valid " <>
                  "object name HEAD); deletion approvals may not persist"}
    end
  end

  describe "effective_oids_many/2" do
    test "deletions key off HEAD pre-image, present files off the index", %{dir: dir} do
      entries = [entry("gone.rs", :deleted), entry("mod.rs", :modified)]

      # Deletion → HEAD blob (pre-image), present → index blob (post-edit),
      # which differs from HEAD's.
      assert Git.effective_oids_many(dir, entries) ==
               {:ok,
                %{"gone.rs" => blob_oid(@head["gone.rs"]), "mod.rs" => blob_oid(@index["mod.rs"])}}
    end

    test "an all-deletions list uses HEAD pre-image OIDs", %{dir: dir} do
      assert Git.effective_oids_many(dir, [entry("a.rs", :deleted), entry("b.rs", :deleted)]) ==
               {:ok, %{"a.rs" => blob_oid("a\n"), "b.rs" => blob_oid("b\n")}}
    end

    test "non-ASCII deletion round-trips its pre-image OID", %{dir: dir} do
      assert Git.effective_oids_many(dir, [entry("wëird.rs", :deleted)]) ==
               {:ok, %{"wëird.rs" => blob_oid(@head["wëird.rs"])}}
    end
  end

  describe "git/2 fixture helper" do
    # The env strip otherwise only matters under a git hook, where GIT_DIR
    # is exported; this poisons GIT_DIR explicitly so the guard fails under
    # an ordinary `mix test` if the strip regresses.
    test "strips an inherited GIT_DIR so git reads dir's repo, not the ambient gitdir",
         %{dir: dir} do
      prev = System.get_env("GIT_DIR")
      System.put_env("GIT_DIR", Meerkat.TestHelpers.tmp_path("meerkat-oids-no-gitdir"))

      on_exit(fn ->
        if prev, do: System.put_env("GIT_DIR", prev), else: System.delete_env("GIT_DIR")
      end)

      assert git(dir, ["rev-parse", "HEAD:kept.rs"]) == blob_oid(@head["kept.rs"])

      assert Git.head_blob_oids_many(dir, ["kept.rs"]) ==
               {:ok, %{"kept.rs" => blob_oid(@head["kept.rs"])}}
    end
  end
end
