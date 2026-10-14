defmodule Meerkat.CljHover.Kondo do
  @moduledoc """
  Runs clj-kondo's analysis and keeps what hover needs: where each var
  is named (`spans`, per file) and each var's definition (`defs`).

  Kondo runs from the repo root, so the repo's `.clj-kondo` config
  applies, with `--cache false`, so it writes nothing there.
  """

  # muex:ignore equivalent: kondo reads the config's first form, so a character after it changes nothing
  @config "{:output {:format :json} :analysis {:arglists true} :linters ^:replace {}}"
  # muex:ignore equivalent: it changes only speed, and kondo ignores the unknown flag a mutant makes
  @parallel "--parallel"

  @type span :: %{
          col: pos_integer(),
          end_col: pos_integer(),
          ns: String.t(),
          name: String.t()
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
          defs: %{optional({String.t(), String.t()}) => definition}
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

      # muex:ignore equivalent: kondo names these files by tmp paths, which no except list could hold
      except = []
      root |> run([dir], except) |> relative_to(dir)
    after
      File.rm_rf(dir)
    end
  end

  @doc """
  Analyse `paths`, relative to `root` or absolute, as they are on disk,
  leaving out definitions in the files named in `except`.
  """
  @spec analyse_paths(String.t(), [String.t()], [String.t()]) :: analysis
  # Kondo given no path prints its help.
  def analyse_paths(_root, [], _except), do: @empty
  def analyse_paths(root, paths, except), do: run(root, paths, except)

  defp run(root, paths, except) do
    args = ["--cache", "false", @parallel, "--config", @config, "--lint" | paths]
    # Kondo exits non-zero when it reports findings; the JSON is what counts.
    {output, _status} = System.cmd("clj-kondo", args, cd: root)

    case Jason.decode(output) do
      {:ok, %{"analysis" => analysis}} ->
        reduce(analysis, except)

      _ ->
        # muex:ignore observability: log text only
        IO.puts(:stderr, "meerkat: clj-kondo gave no analysis for #{Enum.join(paths, " ")}")
        @empty
    end
  end

  defp reduce(analysis, except) do
    # A var kondo can't place names the namespace
    # `clj-kondo/unknown-namespace`, which no classpath holds.
    usages = analysis["var-usages"] || []
    definitions = Enum.reject(analysis["var-definitions"] || [], &(&1["filename"] in except))

    # muex:ignore equivalent: a usage never shares a name position with a definition, so order is moot
    named = Enum.map(usages, &{&1, &1["to"]}) ++ Enum.map(definitions, &{&1, &1["ns"]})

    spans =
      Enum.group_by(
        named,
        fn {v, _ns} -> {v["filename"], v["name-row"]} end,
        fn {v, ns} ->
          %{col: v["name-col"], end_col: v["name-end-col"], ns: ns, name: v["name"]}
        end
      )

    # The last definition of a var wins, as in Clojure: `declare`, then `defn`.
    defs =
      Map.new(definitions, fn d ->
        {{d["ns"], d["name"]},
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
end
