defmodule Meerkat.CljHover do
  @moduledoc """
  Hover docs and source for symbols in a review's Clojure files (see
  `docs/features/clojure-hover.md`).

  One server per review, started on the first page open of a review
  with a Clojure file. It indexes in `handle_continue/2`, so a hover
  that arrives first waits in its mailbox. Each side's diff files are
  analysed from that side's text, the rest of the project from the
  worktree, and dependency namespaces lazily from the classpath, each
  cached for the life of the server.
  """

  # muex:ignore equivalent: the module defines each callback it uses, and gen_server drops unexpected messages itself
  use GenServer

  alias Meerkat.CljHover.{Classpath, Kondo}
  alias Meerkat.Git

  @extensions ~w(.clj .cljc .cljs .edn)
  @source_extensions ["*.clj", "*.cljc", "*.cljs"]

  @type side :: :old | :new

  @type hover :: %{
          name: String.t(),
          macro: boolean(),
          where: String.t(),
          line: pos_integer(),
          arglists: [String.t()],
          doc: String.t() | nil,
          source: String.t()
        }

  @doc "True when `file_name` is a Clojure file hover covers."
  @spec clojure_file?(String.t()) :: boolean()
  def clojure_file?(file_name), do: String.downcase(Path.extname(file_name)) in @extensions

  @doc "Start (or find) the server for `review_id`."
  @spec ensure_started(String.t(), String.t(), [Git.file_diff()]) :: {:ok, pid()}
  def ensure_started(review_id, repo_path, files) do
    spec = {__MODULE__, %{review_id: review_id, repo_path: repo_path, files: files}}

    case DynamicSupervisor.start_child(Meerkat.ReviewServerSup, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc false
  def start_link(%{review_id: review_id} = args),
    do: GenServer.start_link(__MODULE__, args, name: via(review_id))

  @doc false
  def child_spec(args),
    do: %{
      id: {__MODULE__, args.review_id},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary
    }

  @doc """
  The docs and source of the var named at 1-based `line` and `col` of
  file `file_index` on `side`, or nil. Waits for indexing.
  """
  @spec hover(String.t(), non_neg_integer(), side, pos_integer(), pos_integer()) :: hover | nil
  def hover(review_id, file_index, side, line, col) do
    GenServer.call(via(review_id), {:hover, file_index, side, line, col}, :infinity)
  end

  defp via(review_id), do: {:via, Registry, {Meerkat.ReviewRegistry, {__MODULE__, review_id}}}

  @impl true
  def init(%{repo_path: repo_path, files: files}) do
    root =
      case Git.toplevel(repo_path) do
        {:ok, root} -> root
        {:error, _} -> repo_path
      end

    state = %{root: root, files: files, sides: nil, classpath: nil, jars: nil, deps: %{}}
    {:ok, state, {:continue, :index}}
  end

  @impl true
  def handle_continue(:index, %{root: root, files: files} = state) do
    texts = %{old: side_texts(files, :old), new: side_texts(files, :new)}

    tasks =
      Map.new(texts, fn {side, t} ->
        {side, Task.async(fn -> Kondo.analyse_texts(root, t) end)}
      end)

    diff_paths = Enum.flat_map(files, &[&1.file_name, &1.old_file_name])
    outside = Kondo.analyse_paths(root, worktree_roots(root), diff_paths).defs
    classpath = Classpath.read(root)

    sides =
      Map.new(tasks, fn {side, task} ->
        analysis = Task.await(task, :infinity)

        side_defs =
          Map.new(analysis.defs, fn {k, d} ->
            # muex:ignore equivalent: kondo's definitions never hold :text, so put and put_new agree
            {k, Map.put(d, :text, texts[side][d.file])}
          end)

        {side, %{spans: analysis.spans, defs: Map.merge(outside, side_defs)}}
      end)

    {:noreply, %{state | sides: sides, classpath: classpath}}
  end

  @impl true
  def handle_call({:hover, file_index, side, line, col}, _from, state) do
    with %{} = file <- Enum.at(state.files, file_index),
         path = side_path(file, side),
         %{ns: ns, name: name} <- span_at(state.sides[side].spans, path, line, col),
         {d, state} when d != nil <- definition(state, side, ns, name, path) do
      {:reply, render(d, state.root), state}
    else
      {nil, state} -> {:reply, nil, state}
      _ -> {:reply, nil, state}
    end
  end

  # A side a file is absent from, and a binary file, hold "", which
  # defines nothing.
  defp side_texts(files, side) do
    for file <- files,
        path = side_path(file, side),
        clojure_file?(path),
        into: %{},
        do: {path, if(side == :old, do: file.old_content, else: file.new_content)}
  end

  defp side_path(file, :old), do: file.old_file_name || file.file_name
  defp side_path(file, :new), do: file.file_name

  # The top-level entries holding tracked Clojure files: linting those
  # rather than each file keeps the command line short.
  defp worktree_roots(root) do
    case Git.tracked_files(root, @source_extensions) do
      {:ok, paths} ->
        tops = Enum.map(paths, &hd(Path.split(&1)))
        # muex:ignore equivalent: a path linted twice gives the same definitions
        Enum.uniq(tops)

      {:error, _} ->
        []
    end
  end

  defp span_at(spans, path, line, col) do
    spans
    |> Map.get({path, line}, [])
    |> Enum.find(&(&1.col <= col and col < &1.end_col))
  end

  defp definition(state, side, ns, name, path) do
    case Map.get(state.sides[side].defs, {ns, name}) do
      nil -> dependency_definition(state, ns, name, path)
      d -> {d, state}
    end
  end

  defp dependency_definition(state, ns, name, path) do
    # ClojureScript also reaches Clojure namespaces, for macros.
    exts = if Path.extname(path) == ".cljs", do: ~w(.cljs .cljc .clj), else: ~w(.clj .cljc)
    state = list_jars(state)

    case Classpath.find(state.classpath, ns, exts, &Map.fetch!(state.jars, &1)) do
      nil ->
        {nil, state}

      location ->
        {defs, state} = dependency(state, location)
        {Map.get(defs, {ns, name}), state}
    end
  end

  # Listed on the first dependency hover: reading a jar's directory is
  # cheap, and jars don't change.
  defp list_jars(%{jars: nil, classpath: classpath} = state),
    do: %{state | jars: Map.new(classpath, &{&1, Classpath.jar_entries(&1)})}

  defp list_jars(state), do: state

  defp dependency(state, location) do
    case Map.fetch(state.deps, location) do
      {:ok, defs} ->
        {defs, state}

      :error ->
        defs = analyse_dependency(state.root, location)

        # muex:ignore equivalent: this branch runs only when location is absent, so put and put_new agree
        {defs, %{state | deps: Map.put(state.deps, location, defs)}}
    end
  end

  defp analyse_dependency(root, location) do
    rel = elem(location, 2)

    case Classpath.read_file(location) do
      {:ok, text} ->
        where = dependency_where(location, root)

        root
        |> Kondo.analyse_texts(%{rel => text})
        |> Map.fetch!(:defs)
        |> Map.new(fn {k, d} -> {k, Map.merge(d, %{text: text, file: where})} end)

      :error ->
        # muex:ignore observability: log text only
        IO.puts(:stderr, "meerkat: couldn't read #{rel} from #{elem(location, 1)}")
        %{}
    end
  end

  defp dependency_where({:jar, jar, rel}, _root), do: "#{Path.basename(jar)}:#{rel}"
  defp dependency_where({:dir, dir, rel}, root), do: Path.relative_to(Path.join(dir, rel), root)

  defp render(d, root) do
    text = Map.get_lazy(d, :text, fn -> read_worktree(root, d.file) end)

    %{
      name: "#{d.ns}/#{d.name}",
      macro: d.macro,
      where: d.file,
      line: d.row,
      arglists: d.arglists,
      doc: d.doc,
      source: slice(text, d.row, d.end_row)
    }
  end

  defp read_worktree(root, file) do
    case File.read(Path.join(root, file)) do
      {:ok, text} -> text
      {:error, _} -> ""
    end
  end

  defp slice(text, row, end_row) do
    text
    |> String.split("\n")
    |> Enum.slice((row - 1)..(end_row - 1)//1)
    |> Enum.join("\n")
  end
end
