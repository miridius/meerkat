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

    assert %{defs: %{{"a", "x"} => _}} =
             Kondo.analyse_texts(dir, %{"a.clj" => "(ns a)\n(def x 1)\n"})

    assert File.ls!(Path.join(dir, ".clj-kondo")) == []
  end

  test "a var's last definition wins", %{dir: dir} do
    text = "(ns a)\n(declare f)\n(defn f \"Doc.\" [] 1)\n"

    assert %{defs: %{{"a", "f"} => %{doc: "Doc.", row: 3}}} =
             Kondo.analyse_texts(dir, %{"a.clj" => text})
  end

  test "output that isn't an analysis analyses to nothing", %{dir: dir} do
    fake_kondo(dir, "not json")

    assert capture_io(:stderr, fn ->
             assert Kondo.analyse_texts(dir, %{"a.clj" => ""}) == @empty
           end) =~
             "clj-kondo gave no analysis"
  end

  test "an analysis missing its var lists analyses to nothing", %{dir: dir} do
    fake_kondo(dir, ~s({"analysis": {}}))
    assert Kondo.analyse_texts(dir, %{"a.clj" => ""}) == @empty
  end

  describe "cached_file/3, from the user's own kondo runs" do
    # Lints `paths` the way a user's hook or editor does: with the
    # default cache, which a `.clj-kondo` dir turns on.
    defp lint(dir, paths) do
      File.mkdir_p!(Path.join(dir, ".clj-kondo"))
      System.cmd("clj-kondo", ["--lint" | paths], cd: dir, stderr_to_stdout: true)
    end

    defp write(dir, path, text) do
      file = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, text)
      file
    end

    test "names the file a namespace was linted in, linted by relative or absolute path",
         %{dir: dir} do
      a = write(dir, "src/a.clj", "(ns a)\n(def x 1)\n")
      b = write(dir, "src/b.cljc", "(ns b)\n(def x 1)\n")
      lint(dir, ["src/a.clj", b])

      assert Kondo.cached_file(dir, "a", ["clj", "cljc"]) == a
      assert Kondo.cached_file(dir, "b", ["clj", "cljc"]) == b
      # Only the languages asked for.
      refute Kondo.cached_file(dir, "b", ["clj", "cljs"])
      refute Kondo.cached_file(dir, "c", ["clj", "cljc"])
    end

    test "tries the languages in order", %{dir: dir} do
      clj = write(dir, "src/a.clj", "(ns a)\n(def x 1)\n")
      cljs = write(dir, "src/a.cljs", "(ns a)\n(def x 1)\n")
      lint(dir, ["src"])

      assert Kondo.cached_file(dir, "a", ["cljs", "clj"]) == cljs
      assert Kondo.cached_file(dir, "a", ["clj", "cljs"]) == clj
    end

    test "skips a file that is gone, a jar entry, and a cache it can't read", %{dir: dir} do
      gone = write(dir, "src/gone.clj", "(ns gone)\n(def x 1)\n")
      {:ok, _} = :zip.create(~c"#{dir}/dep.jar", [{~c"dep/lib.clj", "(ns dep.lib)\n(def x 1)\n"}])
      lint(dir, ["src", "dep.jar"])
      File.rm!(gone)
      write(dir, ".clj-kondo/.cache/v1/clj/bad.transit.json", "not json")
      write(dir, ".clj-kondo/.cache/v1/clj/odd.transit.json", ~s(["^ ","~:filename",1]))

      refute Kondo.cached_file(dir, "gone", ["clj"])
      assert File.exists?(Path.join(dir, ".clj-kondo/.cache/v1/clj/dep.lib.transit.json"))
      refute Kondo.cached_file(dir, "dep.lib", ["clj"])
      refute Kondo.cached_file(dir, "bad", ["clj"])
      refute Kondo.cached_file(dir, "odd", ["clj"])
    end
  end
end
