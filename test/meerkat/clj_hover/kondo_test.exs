defmodule Meerkat.CljHover.KondoTest do
  # async: false — tests swap PATH and TMPDIR.
  use Meerkat.Case, async: false

  import ExUnit.CaptureIO

  alias Meerkat.CljHover.Kondo

  @empty %{spans: %{}, defs: %{}}

  setup do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-kondo-test")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # A clj-kondo on PATH that prints `output`.
  defp fake_kondo(dir, output) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "out"), output)
    File.write!(Path.join(bin, "clj-kondo"), "#!/bin/sh\ncat '#{bin}/out'\n")
    File.chmod!(Path.join(bin, "clj-kondo"), 0o755)
    Meerkat.TestHelpers.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
  end

  test "texts are analysed at their paths, and their tmp copy is removed", %{dir: dir} do
    tmp = Path.join(dir, "tmp")
    File.mkdir_p!(tmp)
    Meerkat.TestHelpers.put_env("TMPDIR", tmp)

    text = "(ns a)\n\n(defn f\n  \"Doc.\"\n  [x]\n  x)\n\n(defmacro m [] 1)\n"
    analysis = Kondo.analyse_texts(dir, %{"src/a.clj" => text})

    assert analysis.defs[{"a", "f"}] == %{
             ns: "a",
             name: "f",
             file: "src/a.clj",
             row: 3,
             end_row: 6,
             doc: "Doc.",
             arglists: ["[x]"],
             macro: false
           }

    assert %{macro: true, arglists: ["[]"]} = analysis.defs[{"a", "m"}]
    assert %{col: 7, end_col: 8, ns: "a", name: "f"} in analysis.spans[{"src/a.clj", 3}]
    assert File.ls!(tmp) == []
  end

  test "writes no cache into the repo's .clj-kondo", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, ".clj-kondo"))
    File.write!(Path.join(dir, "a.clj"), "(ns a)\n(def x 1)\n")

    assert %{defs: %{{"a", "x"} => _}} = Kondo.analyse_paths(dir, ["a.clj"], [])
    assert File.ls!(Path.join(dir, ".clj-kondo")) == []
  end

  test "a var's last definition wins, and excepted files define nothing", %{dir: dir} do
    File.write!(Path.join(dir, "a.clj"), "(ns a)\n(declare f)\n(defn f \"Doc.\" [] 1)\n")
    File.write!(Path.join(dir, "b.clj"), "(ns b)\n(def y 1)\n")

    assert %{defs: %{{"a", "f"} => %{doc: "Doc.", row: 3}} = defs} =
             Kondo.analyse_paths(dir, ["a.clj", "b.clj"], ["b.clj"])

    refute Map.has_key?(defs, {"b", "y"})
  end

  test "no paths analyse to nothing without running kondo", %{dir: dir} do
    assert capture_io(:stderr, fn ->
             assert Kondo.analyse_paths(dir, [], []) == @empty
           end) == ""
  end

  test "output that isn't an analysis analyses to nothing", %{dir: dir} do
    fake_kondo(dir, "not json")

    assert capture_io(:stderr, fn ->
             assert Kondo.analyse_paths(dir, ["a.clj"], []) == @empty
           end) =~
             "clj-kondo gave no analysis"
  end

  test "an analysis missing its var lists analyses to nothing", %{dir: dir} do
    fake_kondo(dir, ~s({"analysis": {}}))
    assert Kondo.analyse_paths(dir, ["a.clj"], []) == @empty
  end
end
