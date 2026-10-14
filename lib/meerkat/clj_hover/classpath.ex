defmodule Meerkat.CljHover.Classpath do
  @moduledoc """
  The Clojure classpath the user's own tooling already computed, and
  the file on it that holds a namespace. Runs no classpath command.
  """

  @type location :: {:dir, String.t(), String.t()} | {:jar, String.t(), String.t()}

  @doc """
  The classpath entries, absolute: the newest `.cpcache/*.cp` in
  `root`, else the `:classpath` clojure-lsp stored in its
  `.lsp/.cache/db.transit.json`; `[]` with neither.
  """
  @spec read(String.t()) :: [String.t()]
  def read(root) do
    entries = cpcache(root) || lsp_db(root) || []
    Enum.map(entries, &Path.expand(&1, root))
  end

  defp cpcache(root) do
    case Path.wildcard(Path.join(root, ".cpcache/*.cp")) do
      [] ->
        nil

      files ->
        newest = Enum.max_by(files, &File.stat!(&1, time: :posix).mtime)
        newest |> File.read!() |> String.trim() |> String.split(":", trim: true)
    end
  end

  # The db is transit JSON, often tens of MB. The top-level map's
  # `:classpath` is a set: `"~:classpath",["~#set",[...]]`, with the
  # set tag possibly cached as `"^N"`. Only that array is decoded.
  defp lsp_db(root) do
    with {:ok, body} <- File.read(Path.join(root, ".lsp/.cache/db.transit.json")),
         [_, array] <- Regex.run(~r/"~:classpath",\["[^"]*",(\[[^\]]*\])/, body),
         {:ok, entries} <- Jason.decode(array) do
      entries
    else
      _ -> nil
    end
  end

  @doc """
  Where on `entries` the namespace `ns` lives, trying `exts` in order
  for each entry in classpath order. `listing` returns a jar's entry
  names.
  """
  @spec find([String.t()], String.t(), [String.t()], (String.t() -> MapSet.t(String.t()))) ::
          location | nil
  def find(entries, ns, exts, listing) do
    base = ns |> String.replace("-", "_") |> String.replace(".", "/")

    Enum.find_value(entries, fn entry ->
      Enum.find_value(exts, &holding(entry, base <> &1, listing))
    end)
  end

  defp holding(entry, rel, listing) do
    cond do
      String.ends_with?(entry, ".jar") ->
        if MapSet.member?(listing.(entry), rel), do: {:jar, entry, rel}

      File.regular?(Path.join(entry, rel)) ->
        {:dir, entry, rel}

      true ->
        nil
    end
  end

  @doc "A jar's entry names; empty when it can't be read."
  @spec jar_entries(String.t()) :: MapSet.t(String.t())
  def jar_entries(jar) do
    case :zip.list_dir(String.to_charlist(jar)) do
      {:ok, entries} ->
        for {:zip_file, name, _, _, _, _} <- entries, into: MapSet.new(), do: List.to_string(name)

      {:error, _} ->
        MapSet.new()
    end
  end

  @doc "The text of the file at `location`."
  @spec read_file(location) :: {:ok, String.t()} | :error
  def read_file({:dir, dir, rel}) do
    case File.read(Path.join(dir, rel)) do
      {:ok, text} -> {:ok, text}
      {:error, _} -> :error
    end
  end

  def read_file({:jar, jar, rel}) do
    case :zip.extract(String.to_charlist(jar), [
           {:file_list, [String.to_charlist(rel)]},
           :memory
         ]) do
      {:ok, [{_, text}]} -> {:ok, text}
      _ -> :error
    end
  end
end
