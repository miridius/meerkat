defmodule Meerkat.CljHover.ClasspathTest do
  use ExUnit.Case, async: true

  alias Meerkat.CljHover.Classpath

  setup do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-classpath")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write(dir, path, body) do
    file = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, body)
    file
  end

  test "reads the newest .cpcache classpath, relative entries from the root", %{dir: dir} do
    old = write(dir, ".cpcache/old.cp", "stale.jar")
    File.touch!(old, System.os_time(:second) - 60)
    # An empty entry is no entry, not the root.
    write(dir, ".cpcache/new.cp", "src::/abs/lib.jar\n")
    write(dir, ".lsp/.cache/db.transit.json", ~s(["^ ","~:classpath",["~#set",["lsp.jar"]]]))

    assert Classpath.read(dir) == [Path.join(dir, "src"), "/abs/lib.jar"]
  end

  test "falls back to clojure-lsp's stored classpath", %{dir: dir} do
    write(
      dir,
      ".lsp/.cache/db.transit.json",
      ~s(["^ ","~:dep-graph",["^ "],"~:classpath",["^3",["/m2/a.jar","src"]],"~:x",1])
    )

    assert Classpath.read(dir) == ["/m2/a.jar", Path.join(dir, "src")]
  end

  test "is empty with neither", %{dir: dir} do
    assert Classpath.read(dir) == []
    write(dir, ".lsp/.cache/db.transit.json", ~s(["^ ","~:other",1]))
    assert Classpath.read(dir) == []
  end

  test "finds a namespace in classpath order, munging its name", %{dir: dir} do
    write(dir, "first/my_lib/core.cljc", "")
    write(dir, "second/my_lib/core.clj", "(ns my-lib.core)")
    jar = Path.join(dir, "x.jar")
    {:ok, _} = :zip.create(~c"#{jar}", [{~c"my_lib/core.clj", "(ns my-lib.core)"}])
    entries = [jar, Path.join(dir, "first"), Path.join(dir, "second")]

    assert {{:jar, ^jar, "my_lib/core.clj"}, _} =
             Classpath.find(entries, "my-lib.core", [".clj"], %{})

    # Classpath order comes before extension order: "first" holds only the .cljc.
    assert {{:dir, first, "my_lib/core.cljc"}, %{}} =
             Classpath.find(tl(entries), "my-lib.core", [".clj", ".cljc"], %{})

    assert first == Path.join(dir, "first")
    assert {nil, _} = Classpath.find(entries, "absent.ns", [".clj"], %{})
    assert Classpath.read_file({:jar, jar, "my_lib/core.clj"}) == {:ok, "(ns my-lib.core)"}

    assert Classpath.read_file({:dir, Path.join(dir, "second"), "my_lib/core.clj"}) ==
             {:ok, "(ns my-lib.core)"}
  end

  test "a jar is listed once, for its Clojure sources, and only when a lookup reaches it",
       %{dir: dir} do
    write(dir, "src/a/core.clj", "(ns a.core)")
    first = Path.join(dir, "first.jar")
    {:ok, _} = :zip.create(~c"#{first}", [{~c"b/core.cljs", ""}, {~c"B.class", ""}])
    later = Path.join(dir, "later.jar")
    {:ok, _} = :zip.create(~c"#{later}", [{~c"c/core.cljc", ""}])
    entries = [first, Path.join(dir, "src"), later]

    assert {{:dir, _, "a/core.clj"}, jars} = Classpath.find(entries, "a.core", [".clj"], %{})
    assert jars == %{first => MapSet.new(["b/core.cljs"])}

    # The kept listing answers, though the jar is gone.
    File.rm!(first)

    assert {{:jar, ^first, "b/core.cljs"}, ^jars} =
             Classpath.find(entries, "b.core", [".cljs"], jars)

    assert {{:jar, ^later, "c/core.cljc"}, %{^later => _}} =
             Classpath.find(entries, "c.core", [".cljc"], jars)
  end

  test "an unreadable jar or file reads as nothing", %{dir: dir} do
    bad = write(dir, "bad.jar", "not a zip")
    assert Classpath.jar_entries(bad) == MapSet.new()
    assert Classpath.read_file({:jar, bad, "a.clj"}) == :error
    assert Classpath.read_file({:dir, dir, "missing.clj"}) == :error
  end
end
