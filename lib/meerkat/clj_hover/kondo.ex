defmodule Meerkat.CljHover.Kondo do
  @moduledoc """
  Runs clj-kondo's analysis and keeps what hover and go to definition
  need: where each var, local, namespace and keyword is named (`spans`,
  per file), each var's definition (`defs`), each namespace's `ns` form
  (`namespaces`) and each spec keyword's `s/def` (`keywords`). Also
  reads which file the user's own kondo runs found a namespace in.

  Kondo runs from the repo root, so the repo's `.clj-kondo` config
  applies, with `--cache false`, so it writes nothing there.
  """

  # muex:ignore equivalent: only an appended char survives; kondo reads the config's first form
  @config "{:output {:format :json} :analysis {:arglists true :locals true :keywords true} :linters ^:replace {}}"
  # muex:ignore equivalent: only an appended char survives; kondo ignores that unknown flag
  @parallel "--parallel"

  # The registries whose keywords go to definition jumps to.
  @spec_defs ~w(clojure.spec.alpha/def cljs.spec.alpha/def)

  # In a `.cljc` file, `lang` is the reader branch's language; nil
  # elsewhere. A local names the row its binding is on.
  @type span ::
          %{
            kind: :var,
            col: pos_integer(),
            end_col: pos_integer(),
            ns: String.t(),
            name: String.t(),
            lang: String.t() | nil
          }
          | %{
              kind: :ns,
              col: pos_integer(),
              end_col: pos_integer(),
              ns: String.t(),
              lang: String.t() | nil
            }
          | %{
              kind: :keyword,
              col: pos_integer(),
              end_col: pos_integer(),
              ns: String.t(),
              name: String.t()
            }
          | %{kind: :local, col: pos_integer(), end_col: pos_integer(), row: pos_integer()}

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

  # Where a namespace's `ns` form or a keyword's `s/def` is.
  @type place :: %{file: String.t(), row: pos_integer()}

  @type analysis :: %{
          spans: %{optional({String.t(), pos_integer()}) => [span]},
          defs: %{
            optional(
              {ns :: String.t(), name :: String.t(), ext :: String.t(), lang :: String.t() | nil}
            ) => definition
          },
          namespaces: %{optional({ns :: String.t(), ext :: String.t()}) => place},
          keywords: %{optional({ns :: String.t(), name :: String.t()}) => place}
        }

  @empty %{spans: %{}, defs: %{}, namespaces: %{}, keywords: %{}}

  @doc "True when `clj-kondo` is on PATH."
  @spec available?() :: boolean()
  def available?, do: System.find_executable("clj-kondo") != nil

  @doc """
  Analyse `texts`, a map of repo-relative path to file text, as if
  each file sat at its path. The analysis names files by those paths.
  """
  @spec analyse_texts(String.t(), %{optional(String.t()) => String.t()}) :: analysis
  def analyse_texts(root, texts) do
    # muex:ignore equivalent: any name no other run uses serves
    dir = Meerkat.TmpPath.unique("meerkat-kondo")

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
        IO.puts(:stderr, "meerkat: clj-kondo exited #{status} with no analysis in #{root}")
        @empty
    end
  end

  defp reduce(analysis) do
    # A var kondo can't place names the namespace
    # `clj-kondo/unknown-namespace`, which no classpath holds.
    usages = list(analysis, "var-usages")
    definitions = list(analysis, "var-definitions")
    ns_definitions = list(analysis, "namespace-definitions")
    # A keyword without a namespace is never an `s/def`'s.
    keywords = Enum.filter(list(analysis, "keywords"), & &1["ns"])
    locals = list(analysis, "locals")
    binding = Map.new(locals, &{&1["id"], &1["row"]})

    # A `:keys` destructuring's local shares its keyword's position; the
    # local, listed first, answers. A local's binding and a keyword have
    # no separate name position.
    spans =
      Enum.concat([
        Enum.map(usages, &var_span(&1, &1["to"])),
        Enum.map(definitions, &var_span(&1, &1["ns"])),
        Enum.map(list(analysis, "namespace-usages"), &ns_span(&1, &1["to"])),
        Enum.map(ns_definitions, &ns_span(&1, &1["name"])),
        Enum.map(
          list(analysis, "local-usages"),
          &named(&1, %{kind: :local, row: binding[&1["id"]]})
        ),
        Enum.map(locals, &at(&1, %{kind: :local, row: &1["row"]})),
        Enum.map(keywords, &at(&1, %{kind: :keyword, ns: &1["ns"], name: &1["name"]}))
      ])

    # The last definition of a var wins, as in Clojure: `declare`, then
    # `defn`. A namespace's `.clj` and `.cljs` files are separate, and a
    # `.cljc` file defines a var once per reader language, so the key
    # holds the file's extension and that language.
    defs =
      Map.new(definitions, fn d ->
        {{d["ns"], d["name"], Path.extname(d["filename"]), d["lang"]},
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

    %{
      spans: Enum.group_by(spans, &elem(&1, 0), &elem(&1, 1)),
      defs: defs,
      namespaces:
        Map.new(ns_definitions, fn d ->
          {{d["name"], Path.extname(d["filename"])}, %{file: d["filename"], row: d["row"]}}
        end),
      keywords:
        for k <- keywords, k["reg"] in @spec_defs, into: %{} do
          {{k["ns"], k["name"]}, %{file: k["filename"], row: k["row"]}}
        end
    }
  end

  # Kondo leaves out a kind of analysis it found none of.
  defp list(analysis, kind), do: analysis[kind] || []

  defp var_span(v, ns), do: named(v, %{kind: :var, ns: ns, name: v["name"], lang: v["lang"]})

  defp ns_span(v, ns), do: named(v, %{kind: :ns, ns: ns, lang: v["lang"]})

  # Keyed by the file and row of the name.
  defp named(v, span),
    do: place(span, {v["filename"], v["name-row"]}, v["name-col"], v["name-end-col"])

  defp at(v, span), do: place(span, {v["filename"], v["row"]}, v["col"], v["end-col"])

  defp place(span, at, col, end_col) do
    cols = %{col: col, end_col: end_col}
    # muex:ignore equivalent: a span holds no :col or :end_col, so merge order is moot
    {at, Map.merge(span, cols)}
  end

  defp relative_to(analysis, dir) do
    prefix = dir <> "/"
    strip = &String.replace_prefix(&1, prefix, "")
    restrip = &Map.new(&1, fn {key, d} -> {key, %{d | file: strip.(d.file)}} end)

    %{
      spans: Map.new(analysis.spans, fn {{file, row}, list} -> {{strip.(file), row}, list} end),
      defs: restrip.(analysis.defs),
      namespaces: restrip.(analysis.namespaces),
      keywords: restrip.(analysis.keywords)
    }
  end

  @doc """
  The absolute path of the file that the user's own clj-kondo runs
  recorded for namespace `ns` in `root`'s `.clj-kondo/.cache` under
  language `lang` (`"clj"`, `"cljs"` or `"cljc"`); nil when it records
  no file that is still there.

  Each cached namespace is a transit map whose `:filename` is the path
  kondo linted, relative to where it ran or absolute, or `jar:entry`,
  which is no file, so jars are left to the classpath.
  """
  @spec cached_file(String.t(), String.t(), String.t()) :: String.t() | nil
  def cached_file(root, ns, lang) do
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
