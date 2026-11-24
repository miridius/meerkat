defmodule Meerkat.FileTreeTest do
  use ExUnit.Case, async: true

  alias Meerkat.FileTree

  defp entries(names), do: names |> Enum.map(&%{file_name: &1}) |> Enum.with_index()

  # The tree as `{name, children}` for folders and `{name, idx}` for files.
  defp shape(rows) do
    Enum.map(rows, fn
      %{dir: _, name: name, children: kids} -> {name, shape(kids)}
      %{file: {_file, idx}, name: name} -> {name, idx}
    end)
  end

  test "order lists the entries as the tree's file rows read" do
    names = ["lib/web/live/review.ex", "b.ex", "lib/a/x.ex", "lib/y.ex", "A.md"]

    assert names |> entries() |> FileTree.order() |> Enum.map(&elem(&1, 1)) == [4, 1, 3, 2, 0]
  end

  test "lists files before subfolders, each sorted by name ignoring case" do
    tree = FileTree.build(entries(["b.ex", "a/z.ex", "A.md", "B/y.ex", "a/c.ex"]))

    assert shape(tree) == [
             {"A.md", 2},
             {"b.ex", 0},
             {"a", [{"c.ex", 4}, {"z.ex", 1}]},
             {"B", [{"y.ex", 3}]}
           ]
  end

  test "names that differ only in case keep a fixed order" do
    assert shape(FileTree.build(entries(["b", "B"]))) == [{"B", 1}, {"b", 0}]
    assert shape(FileTree.build(entries(["B", "b"]))) == [{"B", 0}, {"b", 1}]
  end

  test "a folder whose only child is a folder shares its row with it" do
    tree = FileTree.build(entries(["lib/web/live/review.ex", "lib/web/live/other.ex", "README"]))

    assert [%{name: "README"}, %{dir: "lib/web/live", name: "lib/web/live", children: kids}] =
             tree

    assert shape(kids) == [{"other.ex", 1}, {"review.ex", 0}]
  end

  test "a folder holding a file and a folder keeps its own row, and paths stay full" do
    tree = FileTree.build(entries(["lib/a/b/x.ex", "lib/y.ex"]))

    assert [%{dir: "lib", name: "lib", children: [file, sub]}] = tree
    assert %{dir: "lib/a/b", name: "a/b"} = sub
    assert %{name: "y.ex", file: {%{file_name: "lib/y.ex"}, 1}} = file
  end

  test "no files make no rows" do
    assert FileTree.build([]) == []
  end
end
