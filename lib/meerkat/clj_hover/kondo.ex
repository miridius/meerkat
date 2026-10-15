defmodule Meerkat.CljHover.Kondo do
  @moduledoc """
  Runs clj-kondo's analysis and keeps what hover needs: where each var
  is named (`spans`, per file) and each var's definition (`defs`). Also
  reads which file the user's own kondo runs found a namespace in.

  Kondo runs from the repo root, so the repo's `.clj-kondo` config
  applies, with `--cache false`, so it writes nothing there.
  """

  # muex:ignore equivalent: only an appended char survives; kondo reads the config's first form
  @config "{:output {:format :json} :analysis {:arglists true} :linters ^:replace {}}"
  # muex:ignore equivalent: only an appended char survives; kondo ignores that unknown flag
  @parallel "--parallel"

  @type span :: %{
          col: pos_integer(),
          end_col: pos_integer(),
          ns: String.t(),
          name: String.t(),
          # In a `.cljc` file, the reader branch's language; nil elsewhere.
          lang: String.t() | nil
        }

  @type definition :: %{
          ns: String.t(),
          name: String.t(),
          file: String.t(),
          row: pos_integer(),
          end_row: pos_integer(),
          doc: String.t() | nil,
          arglists: [String.t()],
          macro: boolean()
        }

  @type analysis :: %{
          spans: %{optional({String.t(), pos_integer()}) => [span]},
          defs: %{
            optional({ns :: String.t(), name :: String.t(), ext :: String.t()}) => definition
          }
        }

  @empty %{spans: %{}, defs: %{}}

  @doc "True when `clj-kondo` is on PATH."
  @spec available?() :: boolean()
  def available?, do: System.find_executable("clj-kondo") != nil

  @doc """
  Analyse `texts`, a map of repo-relative path to file text, as if
  each file sat at its path. The analysis names files by those paths.
  """
  @spec analyse_texts(String.t(), %{optional(String.t()) => String.t()}) :: analysis
  def analyse_texts(root, texts) do
    # The OS pid keeps concurrent meerkats off each other's dirs.
    # muex:ignore equivalent: any name no other run uses serves
    name = "meerkat-kondo-#{System.pid()}-#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), name)

    try do
      for {path, text} <- texts do
        file = Path.join(dir, path)
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, text)
      end

      root |> run(dir) |> relative_to(dir)
    after
      File.rm_rf(dir)
    end
  end

  defp run(root, path) do
    args = ["--cache", "false", @parallel, "--config", @config, "--lint", path]
    # Kondo exits non-zero when it reports findings; the JSON is what counts.
    # Its stderr passes through to meerkat's.
    {output, status} = System.cmd("clj-kondo", args, cd: root)

    case Jason.decode(output) do
      {:ok, %{"analysis" => analysis}} ->
        reduce(analysis)

      _ ->
        # muex:ignore observability: log text only
        IO.puts(:stderr, "meerkat: clj-kondo exited #{status} with no analysis in #{root}")
        @empty
    end
  end

  defp reduce(analysis) do
    # A var kondo can't place names the namespace
    # `clj-kondo/unknown-namespace`, which no classpath holds.
    usages = analysis["var-usages"] || []
    definitions = analysis["var-definitions"] || []

    # muex:ignore equivalent: a usage never shares a name position with a definition, so order is moot
    named = Enum.map(usages, &{&1, &1["to"]}) ++ Enum.map(definitions, &{&1, &1["ns"]})

    spans =
      Enum.group_by(
        named,
        fn {v, _ns} -> {v["filename"], v["name-row"]} end,
        fn {v, ns} ->
          %{
            col: v["name-col"],
            end_col: v["name-end-col"],
            ns: ns,
            name: v["name"],
            lang: v["lang"]
          }
        end
      )

    # The last definition of a var wins, as in Clojure: `declare`, then
    # `defn`. A namespace's `.clj` and `.cljs` files are separate, so the
    # file's extension is in the key.
    defs =
      Map.new(definitions, fn d ->
        {{d["ns"], d["name"], Path.extname(d["filename"])},
         %{
           ns: d["ns"],
           name: d["name"],
           file: d["filename"],
           row: d["row"],
           end_row: d["end-row"],
           doc: d["doc"],
           arglists: d["arglist-strs"] || [],
           macro: d["macro"] == true
         }}
      end)

    %{spans: spans, defs: defs}
  end

  defp relative_to(%{spans: spans, defs: defs}, dir) do
    prefix = dir <> "/"
    strip = &String.replace_prefix(&1, prefix, "")

    %{
      spans: Map.new(spans, fn {{file, row}, list} -> {{strip.(file), row}, list} end),
      defs: Map.new(defs, fn {key, d} -> {key, %{d | file: strip.(d.file)}} end)
    }
  end

  @doc """
  The absolute path of the file that the user's own clj-kondo runs
  recorded for namespace `ns` in `root`'s `.clj-kondo/.cache`, trying
  the cache languages in `langs` (of `"clj"`, `"cljs"`, `"cljc"`) in
  the order given; nil when none records a file that is still there.

  Each cached namespace is a transit map whose `:filename` is the path
  kondo linted, relative to where it ran or absolute, or `jar:entry`,
  which is no file, so jars are left to the classpath.
  """
  @spec cached_file(String.t(), String.t(), [String.t()]) :: String.t() | nil
  def cached_file(root, ns, langs) do
    Enum.find_value(langs, fn lang ->
      cache = Path.join([root, ".clj-kondo", ".cache", "v1", lang, ns <> ".transit.json"])

      with {:ok, body} <- File.read(cache),
           {:ok, ["^ " | pairs]} <- Jason.decode(body),
           file when is_binary(file) <- filename(pairs),
           path = Path.expand(file, root),
           true <- File.regular?(path) do
        path
      else
        _ -> nil
      end
    end)
  end

  # `:filename` appears once, as a top-level key, so transit writes it
  # out rather than as a cache ref.
  defp filename(pairs) do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.find_value(fn
      ["~:filename", file] -> file
      _ -> nil
    end)
  end
end
