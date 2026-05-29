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

  describe "save / load round-trip" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "meerkat-approval-#{:erlang.unique_integer([:positive])}")

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
        Path.join(System.tmp_dir!(), "meerkat-approval-#{:erlang.unique_integer([:positive])}")

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
