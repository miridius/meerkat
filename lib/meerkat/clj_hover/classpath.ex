defmodule Meerkat.CljHover.Classpath do
  @moduledoc """
  The Clojure classpath the user's own tooling already computed, and
  the file on it that holds a namespace. Runs no classpath command.
  """

  @type location :: {:dir, String.t(), String.t()} | {:jar, String.t(), String.t()}

  @typedoc "The jars listed so far, each to its Clojure source entries."
  @type jars :: %{optional(String.t()) => MapSet.t(String.t())}

  @sources ~w(.clj .cljc .cljs)

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
  for each entry in classpath order, and `jars` with each jar the
  search reached listed. A jar already in `jars` is not read again,
  and no jar past the one found is read.
  """
  @spec find([String.t()], String.t(), [String.t()], jars) :: {location | nil, jars}
  def find(entries, ns, exts, jars) do
    base = ns |> String.replace("-", "_") |> String.replace(".", "/")

    Enum.reduce_while(entries, {nil, jars}, fn entry, {nil, jars} ->
      jars = listed(jars, entry)

      case Enum.find_value(exts, &holding(entry, base <> &1, jars)) do
        nil -> {:cont, {nil, jars}}
        location -> {:halt, {location, jars}}
      end
    end)
  end

  defp listed(jars, entry) do
    if jar?(entry), do: Map.put_new_lazy(jars, entry, fn -> jar_entries(entry) end), else: jars
  end

  defp jar?(entry), do: String.ends_with?(entry, ".jar")

  defp holding(entry, rel, jars) do
    cond do
      jar?(entry) ->
        if MapSet.member?(jars[entry], rel), do: {:jar, entry, rel}

      File.regular?(Path.join(entry, rel)) ->
        {:dir, entry, rel}

      true ->
        nil
    end
  end

  @doc """
  A jar's Clojure source entry names; empty when it can't be read.
  Only those are kept: they are all a lookup asks for, and a Java
  jar holds thousands of others.
  """
  @spec jar_entries(String.t()) :: MapSet.t(String.t())
  def jar_entries(jar) do
    # Read whole first: `:zip` reading a jar from disk is many times slower.
    with {:ok, bytes} <- File.read(jar),
         {:ok, entries} <- :zip.list_dir(bytes) do
      for {:zip_file, name, _, _, _, _} <- entries,
          name = List.to_string(name),
          Path.extname(name) in @sources,
          into: MapSet.new(),
          do: name
    else
      _ -> MapSet.new()
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
    with {:ok, bytes} <- File.read(jar),
         {:ok, [{_, text}]} <-
           :zip.extract(bytes, [{:file_list, [String.to_charlist(rel)]}, :memory]) do
      {:ok, text}
    else
      _ -> :error
    end
  end
end
