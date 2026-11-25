defmodule Meerkat.CljHover do
  @moduledoc """
  Hover docs and source, and go to definition, for symbols in a
  review's Clojure files (see `docs/features/clojure-hover.md` and
  `docs/features/clojure-go-to-definition.md`).

  One server per review, started on the first page open of a review
  with a Clojure file. It analyses each side's diff files from that
  side's text in `handle_continue/2`, so a request that arrives first
  waits in its mailbox. Other namespaces are analysed lazily, one file
  each, found through the user's clj-kondo cache or the classpath, and
  cached for the life of the server.

  A definition outside the diff opens in a file view: the file's
  reviewed text, analysed in turn so hover and go to definition work
  in it.
  """

  use GenServer

  alias Meerkat.CljHover.{Classpath, Kondo}
  alias Meerkat.Git

  @extensions ~w(.clj .cljc .cljs .edn)

  @type side :: :old | :new

  @typedoc "A diff file's index, or the file view of the file `where` names."
  @type target :: non_neg_integer() | {:view, String.t()}

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

  @typedoc """
  Where a symbol, at columns `col` to before `end_col`, is defined: a
  line of a diff file on a side, or of a file view.
  """
  @type jump :: %{
          col: pos_integer(),
          end_col: pos_integer(),
          to:
            %{file_index: non_neg_integer(), side: side, line: pos_integer()}
            | %{where: String.t(), line: pos_integer()}
        }

  @type view :: %{where: String.t(), text: String.t()}

  @doc "True when `file_name` is a Clojure file hover covers."
  @spec clojure_file?(String.t()) :: boolean()
  def clojure_file?(file_name), do: String.downcase(Path.extname(file_name)) in @extensions

  @doc """
  Start (or find) the server for `review_id`. `ref` holds the reviewed
  text of the repo files the diff doesn't change.
  """
  @spec ensure_started(String.t(), String.t(), [Git.file_diff()], String.t() | nil) ::
          {:ok, pid()}
  def ensure_started(review_id, repo_path, files, ref) do
    spec = {__MODULE__, %{review_id: review_id, repo_path: repo_path, files: files, ref: ref}}

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
  `target` on `side`, or nil. Waits for indexing.
  """
  @spec hover(String.t(), target, side, pos_integer(), pos_integer()) :: hover | nil
  def hover(review_id, target, side, line, col) do
    GenServer.call(via(review_id), {:hover, target, side, line, col}, :infinity)
  end

  @doc """
  Where the var, local, namespace or spec keyword named at 1-based
  `line` and `col` of `target` on `side` is defined; `:other_side` when
  only the other side of the diff defines it; nil when nothing does.
  Waits for indexing.
  """
  @spec definition(String.t(), target, side, pos_integer(), pos_integer()) ::
          jump | :other_side | nil
  def definition(review_id, target, side, line, col) do
    GenServer.call(via(review_id), {:definition, target, side, line, col}, :infinity)
  end

  @doc "The file view a jump named `where` lands in, or nil."
  @spec view(String.t(), String.t()) :: view | nil
  def view(review_id, where), do: GenServer.call(via(review_id), {:view, where}, :infinity)

  defp via(review_id), do: {:via, Registry, {Meerkat.ReviewRegistry, {__MODULE__, review_id}}}

  @impl true
  def init(%{repo_path: repo_path, files: files, ref: ref}) do
    state = %{
      root: Git.root(repo_path),
      ref: ref,
      files: files,
      sides: nil,
      classpath: nil,
      jars: %{},
      located: %{},
      outside: %{},
      views: %{},
      spec_files: %{}
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

    sides =
      Map.new(tasks, fn {side, task} ->
        analysis = Task.await(task, :infinity)

        # A diff file is the repo's own.
        defs =
          Map.new(analysis.defs, fn {k, d} ->
            # muex:ignore equivalent: kondo's definitions hold neither :text nor :in_repo, so merge order doesn't matter
            {k, Map.merge(d, %{text: texts[side][d.file], in_repo: true})}
          end)

        {side, %{analysis | defs: defs}}
      end)

    {:noreply, %{state | sides: sides}}
  end

  @impl true
  def handle_call({:hover, target, side, line, col}, _from, state) do
    with %{} = at <- at(state, target, side),
         %{kind: :var} = span <- span_at(at.spans, at.path, line, col),
         {d, state} when d != nil <- definition(state, side, span, at) do
      {:reply, render(d), state}
    else
      {nil, state} -> {:reply, nil, state}
      _ -> {:reply, nil, state}
    end
  end

  def handle_call({:definition, target, side, line, col}, _from, state) do
    with %{} = at <- at(state, target, side),
         %{} = span <- span_at(at.spans, at.path, line, col) do
      {answer, state} = definition_answer(state, side, at, span)
      {:reply, answer, state}
    else
      _ -> {:reply, nil, state}
    end
  end

  def handle_call({:view, where}, _from, state) do
    case state.views[where] do
      %{text: text} -> {:reply, %{where: where, text: text}, state}
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

  # The spans and path of `target` on `side`, the vars it defines beyond
  # the side's diff files, and where a jump inside it lands.
  defp at(state, file_index, side) when is_integer(file_index) do
    with %{} = file <- Enum.at(state.files, file_index) do
      %{
        spans: state.sides[side].spans,
        path: side_path(file, side),
        defs: %{},
        in: {:diff, file_index}
      }
    end
  end

  defp at(state, {:view, where}, _side) do
    with %{analysis: analysis, path: path, defs: defs} <- state.views[where] do
      %{spans: analysis.spans, path: path, defs: defs, in: {:view, where}}
    end
  end

  defp span_at(spans, path, line, col) do
    spans
    |> Map.get({path, line}, [])
    # muex:ignore equivalent: both checks are pure and every span has :col and :end_col, so order is moot
    |> Enum.find(&(&1.col <= col and col < &1.end_col))
  end

  # The language a span in `path` reads as, and the extensions of the
  # files its namespaces are looked for in, in order.
  defp lang_exts(span, path) do
    # A `.cljc` file's reader branch names its language.
    lang = span[:lang] || String.trim_leading(Path.extname(path), ".")
    # ClojureScript also reaches Clojure namespaces, for macros.
    {lang, if(lang == "cljs", do: ~w(.cljs .cljc .clj), else: ~w(.clj .cljc))}
  end

  # A file view's own vars answer when no diff file defines them, so its
  # file needn't be found again by namespace.
  defp definition(state, side, %{ns: ns, name: name} = span, at) do
    {lang, exts} = lang_exts(span, at.path)
    var = {ns, name}

    case defined(state.sides[side].defs, var, exts, lang) || defined(at.defs, var, exts, lang) do
      nil -> outside_definition(state, var, exts, lang)
      d -> {d, state}
    end
  end

  # The var's definition in the first of `exts` that defines it; in a
  # `.cljc` file, its reader branch for `lang`.
  defp defined(defs, {ns, name}, exts, lang),
    do: Enum.find_value(exts, &defs[{ns, name, &1, if(&1 == ".cljc", do: lang)}])

  # A var the side's diff files don't define: its namespace's file for
  # the first of `exts` that defines it, each file analysed on first
  # hover. A diff file answers only from the side's text.
  defp outside_definition(state, var, exts, lang) do
    first_found(exts, state, fn ext, state -> defined_in(state, var, ext, lang) end)
  end

  # The first non-nil `fun.(item, state)` over `items`, threading state.
  defp first_found(items, state, fun) do
    Enum.reduce_while(items, {nil, state}, fn item, {nil, state} ->
      case fun.(item, state) do
        {nil, state} -> {:cont, {nil, state}}
        found -> {:halt, found}
      end
    end)
  end

  # The var's definition in its namespace's file with extension `ext`.
  defp defined_in(state, {ns, _} = var, ext, lang) do
    {location, state} = outside_location(state, ns, ext)

    if location == nil do
      {nil, state}
    else
      {defs, state} = analysed(state, location)
      {defined(defs, var, [ext], lang), state}
    end
  end

  # The file of namespace `ns` with extension `ext` outside the diff.
  defp outside_location(state, ns, ext) do
    {location, state} = located(state, ns, ext)
    if location == nil or diff_file?(state, location), do: {nil, state}, else: {location, state}
  end

  # Looked up once per namespace and extension, so the file first found
  # answers for the rest of the review.
  defp located(state, ns, ext) do
    case Map.fetch(state.located, {ns, ext}) do
      {:ok, location} ->
        {location, state}

      :error ->
        {location, state} = locate(state, ns, ext)

        # muex:ignore equivalent: this branch runs only when the key is absent, so put and put_new agree
        {location, %{state | located: Map.put(state.located, {ns, ext}, location)}}
    end
  end

  # The file the user's kondo runs found the namespace in, else the
  # classpath's.
  defp locate(state, ns, ext) do
    case Kondo.cached_file(state.root, ns, String.trim_leading(ext, ".")) do
      nil ->
        state = read_classpath(state)
        {location, jars} = Classpath.find(state.classpath, ns, ext, state.jars)
        {location, %{state | jars: jars}}

      file ->
        {{:dir, Path.dirname(file), Path.basename(file)}, state}
    end
  end

  # A jar's `where` names the jar, so it is never a diff file.
  defp diff_file?(state, location),
    do:
      where(location, state.root) in Enum.flat_map(state.files, &[&1.file_name, &1.old_file_name])

  # Read on the first classpath lookup, so a review hovering only what
  # its diff and kondo's cache answer never reads it: clojure-lsp's db
  # can be tens of MB.
  defp read_classpath(%{classpath: nil, root: root} = state),
    do: %{state | classpath: Classpath.read(root)}

  defp read_classpath(state), do: state

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

        root
        |> Kondo.analyse_texts(%{rel => text})
        |> Map.fetch!(:defs)
        |> Map.new(fn {k, d} ->
          {k, Map.merge(d, %{text: text, file: where, in_repo: in_repo?(location, where)})}
        end)

      :error ->
        # muex:ignore observability: log text only
        IO.puts(:stderr, "meerkat: couldn't read #{rel} from #{elem(location, 1)}")
        %{}
    end
  end

  # A jar, or a directory outside the repo, is a dependency's.
  # muex:ignore equivalent: swapping the two pure checks joined by `and` changes nothing
  defp in_repo?(location, where), do: elem(location, 0) == :dir and Path.type(where) == :relative

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

  ## Go to definition

  defp definition_answer(state, side, at, span) do
    case jump_to(state, side, at, span) do
      {nil, state} -> {if(other_side?(state, side, at.path, span), do: :other_side), state}
      {to, state} -> {%{col: span.col, end_col: span.end_col, to: to}, state}
    end
  end

  # Where `span`, in `at` on `side`, is defined: a diff file's line on
  # `side`, or a file view's.
  defp jump_to(state, side, at, %{kind: :local} = span), do: {place(at.in, side, span.row), state}

  defp jump_to(state, side, at, %{kind: :var} = span) do
    case definition(state, side, span, at) do
      {nil, state} ->
        {nil, state}

      {d, state} ->
        case diff_index(state.files, side, d.file) do
          nil ->
            {lang, _} = lang_exts(span, at.path)
            ext = Path.extname(d.file)

            in_view(
              state,
              location_of(state, d.file),
              &defined(&1.defs, {d.ns, d.name}, [ext], lang)
            )

          index ->
            {%{file_index: index, side: side, line: d.row}, state}
        end
    end
  end

  defp jump_to(state, side, at, %{kind: :ns, ns: ns} = span) do
    {_, exts} = lang_exts(span, at.path)

    case Enum.find_value(exts, &state.sides[side].namespaces[{ns, &1}]) do
      nil ->
        first_found(exts, state, &ns_in_view(&2, ns, &1))

      %{file: file, row: row} ->
        {%{file_index: diff_index(state.files, side, file), side: side, line: row}, state}
    end
  end

  defp jump_to(state, side, _at, %{kind: :keyword, ns: ns, name: name}) do
    case state.sides[side].keywords[{ns, name}] do
      nil ->
        {files, state} = spec_files(state, ns, name)

        first_found(files, state, fn file, state ->
          in_view(state, {:dir, state.root, file}, & &1.keywords[{ns, name}])
        end)

      %{file: file, row: row} ->
        {%{file_index: diff_index(state.files, side, file), side: side, line: row}, state}
    end
  end

  # Namespace `ns`'s file with extension `ext` outside the diff, in a
  # file view.
  defp ns_in_view(state, ns, ext) do
    case outside_location(state, ns, ext) do
      {nil, state} -> {nil, state}
      {location, state} -> in_view(state, location, & &1.namespaces[{ns, ext}])
    end
  end

  defp place({:diff, file_index}, side, line),
    do: %{file_index: file_index, side: side, line: line}

  defp place({:view, where}, _side, line), do: %{where: where, line: line}

  # The index of the diff file whose path on `side` is `path`, or nil:
  # a file outside the diff never shares a diff file's path.
  defp diff_index(files, side, path), do: Enum.find_index(files, &(side_path(&1, side) == path))

  # The location a definition outside the diff was read from: an open
  # file view's, or a file read for hover.
  defp location_of(state, where) do
    case state.views[where] do
      %{location: location} -> location
      nil -> Enum.find(Map.keys(state.outside), &(where(&1, state.root) == where))
    end
  end

  # The line of `location`'s file view that `find` finds in its
  # analysis, opening the view.
  defp in_view(state, location, find) do
    {view, state} = view_of(state, location)

    case view && find.(view.analysis) do
      %{row: row} -> {%{where: view.where, line: row}, state}
      _ -> {nil, state}
    end
  end

  # The file view of `location`, read and analysed on first use: a repo
  # file's text at the reviewed ref, a dependency's as it is. Nil when
  # the text can't be read.
  defp view_of(state, location) do
    where = where(location, state.root)

    case Map.fetch(state.views, where) do
      {:ok, view} ->
        {view, state}

      :error ->
        view = read_view(state, location, where)

        # muex:ignore equivalent: this branch runs only when the key is absent, so put and put_new agree
        {view, %{state | views: Map.put(state.views, where, view)}}
    end
  end

  defp read_view(state, location, where) do
    {text, path} =
      if in_repo?(location, where),
        do: {Git.show(state.root, state.ref, where), where},
        else: {Classpath.read_file(location), elem(location, 2)}

    case text do
      {:ok, text} ->
        analysis = Kondo.analyse_texts(state.root, %{path => text})
        own = %{text: text, file: where, in_repo: in_repo?(location, where)}

        %{
          where: where,
          location: location,
          path: path,
          text: text,
          analysis: analysis,
          defs: Map.new(analysis.defs, fn {k, d} -> {k, Map.merge(d, own)} end)
        }

      :error ->
        nil
    end
  end

  # The repo's Clojure files at the reviewed ref, outside the diff, with
  # a line that may `s/def` keyword `ns/name`; the namespace's own file
  # first. Searched once per keyword.
  defp spec_files(state, ns, name) do
    case Map.fetch(state.spec_files, {ns, name}) do
      {:ok, files} ->
        {files, state}

      :error ->
        # `def` and the keyword, maybe written `::name` or `::alias/name`.
        pattern = "def[[:space:]]+::?([^[:space:]/]+/)?#{Regex.escape(name)}([[:space:]()]|$)"
        diff = Enum.flat_map(state.files, &[&1.file_name, &1.old_file_name])
        own = ns |> String.replace("-", "_") |> String.replace(".", "/")

        files =
          state.root
          |> Git.grep(state.ref, pattern, ~w(*.clj *.cljc *.cljs))
          |> Enum.reject(&(&1 in diff))
          |> Enum.sort_by(&(not String.contains?(&1, own)))

        # muex:ignore equivalent: this branch runs only when the key is absent, so put and put_new agree
        {files, %{state | spec_files: Map.put(state.spec_files, {ns, name}, files)}}
    end
  end

  # Whether the other side's diff files define what `span` names.
  defp other_side?(state, side, path, span) do
    other = state.sides[if(side == :old, do: :new, else: :old)]
    {lang, exts} = lang_exts(span, path)

    case span do
      %{kind: :var, ns: ns, name: name} -> defined(other.defs, {ns, name}, exts, lang) != nil
      %{kind: :ns, ns: ns} -> Enum.any?(exts, &Map.has_key?(other.namespaces, {ns, &1}))
      %{kind: :keyword, ns: ns, name: name} -> Map.has_key?(other.keywords, {ns, name})
    end
  end
end
