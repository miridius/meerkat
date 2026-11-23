defmodule Meerkat.FileTree do
  @moduledoc """
  The file filter's folder tree: in each folder, files first, then
  subfolders, each sorted by name, and, as in GitHub's PR file tree, a
  folder whose only child is a folder shares its row with it
  (`lib/meerkat_web/live`).
  """

  @typedoc "A folder row, keyed by the full path of its deepest folder, holding its rows."
  @type dir :: %{dir: String.t(), name: String.t(), children: [tree_node()]}

  @typedoc "A file row, holding the entry it was built from."
  @type file :: %{file: entry(), name: String.t()}

  @type tree_node :: dir() | file()

  @typedoc """
  A tuple whose first element is a file (a map with `:file_name`),
  followed by whatever its row needs, such as the file's index.
  """
  @type entry :: tuple()

  @doc "The tree's top-level rows for `entries`."
  @spec build([entry()]) :: [tree_node()]
  def build(entries) do
    entries
    |> Enum.map(&{String.split(elem(&1, 0).file_name, "/"), &1})
    |> rows("")
  end

  @doc "`entries` in the order the tree's file rows read, top to bottom."
  @spec order([entry()]) :: [entry()]
  def order(entries), do: entries |> build() |> Enum.flat_map(&row_entries/1)

  defp row_entries(%{file: entry}), do: [entry]
  defp row_entries(%{children: children}), do: Enum.flat_map(children, &row_entries/1)

  defp rows(items, parent) do
    {files, dirs} = Enum.split_with(items, &match?({[_name], _entry}, &1))

    dir_rows =
      dirs
      |> Enum.group_by(fn {[name | _], _} -> name end, fn {[_ | rest], entry} -> {rest, entry} end)
      |> Enum.sort_by(fn {name, _} -> sort_key(name) end)
      |> Enum.map(fn {name, children} -> dir_row(name, Path.join(parent, name), children) end)

    file_rows =
      files
      |> Enum.map(fn {[name], entry} -> %{file: entry, name: name} end)
      |> Enum.sort_by(&sort_key(&1.name))

    file_rows ++ dir_rows
  end

  defp dir_row(name, path, children) do
    case rows(children, path) do
      [%{dir: sub_path, name: sub_name, children: sub_children}] ->
        %{dir: sub_path, name: name <> "/" <> sub_name, children: sub_children}

      kids ->
        %{dir: path, name: name, children: kids}
    end
  end

  # Case-insensitive, as GitHub sorts; the name itself breaks ties so
  # the order of different names never depends on the diff's.
  defp sort_key(name), do: {String.downcase(name), name}
end
