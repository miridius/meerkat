defmodule Meerkat.FileTree do
  @moduledoc """
  The file filter's folder tree, laid out as GitHub lays out a PR's
  file tree: in each folder, subfolders first, then files, each sorted
  by name, and a folder whose only child is a folder shares its row
  with it (`lib/meerkat_web/live`).
  """

  @typedoc "A folder row, keyed by its full path, holding its rows."
  @type dir :: %{dir: String.t(), name: String.t(), children: [tree_node()]}

  @typedoc "A file row, holding the entry it was built from."
  @type file :: %{file: entry(), name: String.t()}

  @type tree_node :: dir() | file()

  @typedoc "A file and its index in the review's file list."
  @type entry :: {%{file_name: String.t()}, non_neg_integer()}

  @doc "The tree's top-level rows for `entries`."
  @spec build([entry()]) :: [tree_node()]
  def build(entries) do
    entries
    |> Enum.map(fn {file, _idx} = entry -> {String.split(file.file_name, "/"), entry} end)
    |> rows("")
  end

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

    dir_rows ++ file_rows
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
  # the order never depends on the diff's.
  defp sort_key(name), do: {String.downcase(name), name}
end
