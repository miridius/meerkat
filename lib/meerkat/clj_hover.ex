defmodule Meerkat.CljHover do
  @moduledoc """
  Hover docs and source for symbols in a review's Clojure files (see
  `docs/features/clojure-hover.md`).

  One server per review, started on the first page open of a review
  with a Clojure file. It analyses each side's diff files from that
  side's text in `handle_continue/2`, so a hover that arrives first
  waits in its mailbox. Other namespaces are analysed lazily, one file
  each, found through the user's clj-kondo cache or the classpath, and
  cached for the life of the server.
  """

  # muex:ignore equivalent: the module defines each callback it uses, and gen_server drops unexpected messages itself
  use GenServer

  alias Meerkat.CljHover.{Classpath, Kondo}
  alias Meerkat.Git

  @extensions ~w(.clj .cljc .cljs .edn)

  @type side :: :old | :new

  @type hover :: %{
          name: String.t(),
          macro: boolean(),
          where: String.t(),
          in_repo: boolean(),
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

    state = %{
      root: root,
      files: files,
      sides: nil,
      classpath: nil,
      jars: nil,
      located: %{},
      outside: %{}
    }

    {:ok, state, {:continue, :index}}
  end

  # Kondo's cache can't stand in here: it records no usages, so not
  # which var a symbol names, nor docs, and the old side was never linted.
  @impl true
  def handle_continue(:index, %{root: root, files: files} = state) do
    texts = %{old: side_texts(files, :old), new: side_texts(files, :new)}

    tasks =
      Map.new(texts, fn {side, t} ->
        {side, Task.async(fn -> Kondo.analyse_texts(root, t) end)}
      end)

    classpath = Classpath.read(root)

    sides =
      Map.new(tasks, fn {side, task} ->
        analysis = Task.await(task, :infinity)

        # A diff file is the repo's own.
        defs =
          Map.new(analysis.defs, fn {k, d} ->
            # muex:ignore equivalent: kondo's definitions hold neither :text nor :in_repo, so merge order doesn't matter
            {k, Map.merge(d, %{text: texts[side][d.file], in_repo: true})}
          end)

        {side, %{spans: analysis.spans, defs: defs}}
      end)

    {:noreply, %{state | sides: sides, classpath: classpath}}
  end

  @impl true
  def handle_call({:hover, file_index, side, line, col}, _from, state) do
    with %{} = file <- Enum.at(state.files, file_index),
         path = side_path(file, side),
         %{ns: ns, name: name} <- span_at(state.sides[side].spans, path, line, col),
         {d, state} when d != nil <- definition(state, side, ns, name, path) do
      {:reply, render(d), state}
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

  defp span_at(spans, path, line, col) do
    spans
    |> Map.get({path, line}, [])
    |> Enum.find(&(&1.col <= col and col < &1.end_col))
  end

  defp definition(state, side, ns, name, path) do
    case Map.get(state.sides[side].defs, {ns, name}) do
      nil -> outside_definition(state, ns, name, path)
      d -> {d, state}
    end
  end

  # A namespace no diff file defines: the one file holding it, analysed
  # on first hover. A diff file answers only from the side's text.
  defp outside_definition(state, ns, name, path) do
    # ClojureScript also reaches Clojure namespaces, for macros.
    exts = if Path.extname(path) == ".cljs", do: ~w(.cljs .cljc .clj), else: ~w(.clj .cljc)
    {location, state} = located(state, ns, exts)

    if location == nil or diff_file?(state, location) do
      {nil, state}
    else
      {defs, state} = analysed(state, location)
      {Map.get(defs, {ns, name}), state}
    end
  end

  # Looked up once per namespace and language, so the file first found
  # answers for the rest of the review.
  defp located(state, ns, exts) do
    case Map.fetch(state.located, {ns, exts}) do
      {:ok, location} ->
        {location, state}

      :error ->
        {location, state} = locate(state, ns, exts)

        # muex:ignore equivalent: this branch runs only when the key is absent, so put and put_new agree
        {location, %{state | located: Map.put(state.located, {ns, exts}, location)}}
    end
  end

  # The file the user's kondo runs found the namespace in, else the
  # classpath's.
  defp locate(state, ns, exts) do
    langs = Enum.map(exts, &String.trim_leading(&1, "."))

    case Kondo.cached_file(state.root, ns, langs) do
      nil ->
        state = list_jars(state)
        {Classpath.find(state.classpath, ns, exts, &Map.fetch!(state.jars, &1)), state}

      file ->
        {{:dir, Path.dirname(file), Path.basename(file)}, state}
    end
  end

  # A jar's `where` names the jar, so it is never a diff file.
  defp diff_file?(state, location),
    do:
      where(location, state.root) in Enum.flat_map(state.files, &[&1.file_name, &1.old_file_name])

  # Listed on the first classpath lookup: reading a jar's directory is
  # cheap, and jars don't change.
  defp list_jars(%{jars: nil, classpath: classpath} = state),
    do: %{state | jars: Map.new(classpath, &{&1, Classpath.jar_entries(&1)})}

  defp list_jars(state), do: state

  defp analysed(state, location) do
    case Map.fetch(state.outside, location) do
      {:ok, defs} ->
        {defs, state}

      :error ->
        defs = analyse(state.root, location)

        # muex:ignore equivalent: this branch runs only when location is absent, so put and put_new agree
        {defs, %{state | outside: Map.put(state.outside, location, defs)}}
    end
  end

  defp analyse(root, location) do
    rel = elem(location, 2)

    case Classpath.read_file(location) do
      {:ok, text} ->
        where = where(location, root)

        # A jar, or a directory outside the repo, is a dependency's.
        in_repo = elem(location, 0) == :dir and Path.type(where) == :relative

        root
        |> Kondo.analyse_texts(%{rel => text})
        |> Map.fetch!(:defs)
        |> Map.new(fn {k, d} ->
          {k, Map.merge(d, %{text: text, file: where, in_repo: in_repo})}
        end)

      :error ->
        # muex:ignore observability: log text only
        IO.puts(:stderr, "meerkat: couldn't read #{rel} from #{elem(location, 1)}")
        %{}
    end
  end

  defp where({:jar, jar, rel}, _root), do: "#{Path.basename(jar)}:#{rel}"
  defp where({:dir, dir, rel}, root), do: Path.relative_to(Path.join(dir, rel), root)

  defp render(d) do
    %{
      name: "#{d.ns}/#{d.name}",
      macro: d.macro,
      where: d.file,
      in_repo: d.in_repo,
      line: d.row,
      arglists: d.arglists,
      doc: d.doc,
      source: slice(d.text, d.row, d.end_row)
    }
  end

  defp slice(text, row, end_row) do
    text
    |> String.split("\n")
    |> Enum.slice((row - 1)..(end_row - 1)//1)
    |> Enum.join("\n")
  end
end
