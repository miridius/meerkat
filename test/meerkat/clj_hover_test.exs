defmodule Meerkat.CljHoverTest do
  # Hover answers on a real staged review, analysed by the real clj-kondo.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, import_commits: 2, read_tree: 3]

  alias Meerkat.{CljHover, Git}

  # Each top-level directory holds one kind of Clojure file, which the
  # user's own kondo run has linted. Only the jar and `vendor` are on
  # the classpath, so project vars answer only through kondo's cache.
  @base %{
    "src/app/util.clj" => """
    (ns app.util)

    (defn helper
      "Old doc."
      [x]
      x)

    (defn gone [] 1)
    """,
    # Specs outside the diff: one in the keyword's own namespace, one
    # registering another namespace's keyword.
    "src/app/specs.clj" => """
    (ns app.specs
      (:require [clojure.spec.alpha :as s]))

    (s/def ::id int?)
    (s/def :user/name string?)
    """,
    "src/app/other.clj" => """
    (ns app.other)

    (defn thing
      "Other doc."
      [z]
      z)

    (def limit "Limit doc." 10)
    """,
    # A namespace split over two files: the diff's file answers. Its
    # spec opens it in a file view.
    "src/app/util_copy.clj" => """
    (ns app.util
      (:require [clojure.spec.alpha :as s]))

    (defn helper "Copy doc." [x] x)

    (s/def ::copy int?)

    (defn copy-fn [] (copy-fn))
    """,
    "src/app/core.clj" => """
    (ns app.core
      (:require [app.util :as u]
                [app.other :as o]))

    (defn run [y]
      (u/helper (o/thing y)) (u/later))
    """,
    # A namespace, and a spec, the diff deletes.
    "src/app/dropped.clj" => """
    (ns app.dropped
      (:require [clojure.spec.alpha :as s]))

    (s/def ::gone int?)
    """,
    # A keyword two files `s/def`: its own namespace's file answers.
    "src/app/aaa.clj" => """
    (ns app.aaa
      (:require [clojure.spec.alpha :as s]))

    (s/def :app.my-specs/key string?)
    """,
    "src/app/my_specs.clj" => """
    (ns app.my-specs
      (:require [clojure.spec.alpha :as s]))

    (s/def ::key int?)
    """,
    "web/app/specs.cljs" => """
    (ns app.web-specs
      (:require [cljs.spec.alpha :as s]))

    (s/def ::w int?)
    """,
    # Files the search for `:user/name`'s spec passes over: not Clojure,
    # no `s/def`, and another keyword's.
    "README.md" => """
    (s/def :user/name string?)
    """,
    "doc/uses.clj" => """
    (get {} :user/name)
    """,
    "doc/names.clj" => """
    (s/def :user/namex string?)
    """,
    "src/app/top.clj" => """
    (ns app.top) (defn top-fn "Top doc." [] 1)
    """,
    "shared/app/common.cljc" => """
    (ns app.common)

    (defn common-fn "Common doc." [] 1)
    """,
    "web/app/view.cljs" => """
    (ns app.view)

    (defn view-fn "View doc." [] 1)
    """,
    "web/app/ui.cljs" => """
    (ns app.ui)
    """
  }

  @staged %{
    "src/app/util.clj" => """
    (ns app.util)

    (defn helper
      "New doc."
      [x]
      x)

    (defn later [] 1)
    """,
    "src/app/core.clj" => """
    (ns app.core
      (:require [app.util :as u]
                [app.other :as o]
                [app.common :as c]
                [app.draft :as d]
            [app.top :as tp]
                [dep.lib :as lib]
                [dep.shared :as sh]
                [vend.tool :as t]
                [vend.locked :as l] [ext.lib :as x] [app.plat :as p] [app.dropped :as dr]))

    (defn run [y]
      (lib/dep-fn (u/helper (o/thing y))))

    (defn more []
      (c/common-fn) (d/draft-fn) (sh/shared-fn 1) (t/tool-fn) (l/locked-fn) o/limit (tp/top-fn) (u/extra) (x/ext-fn) (p/now))

    (defn specs [] [:app.specs/id :user/name :app.model/here :app.specs/nope (u/gone) :app.dropped/gone :app.my-specs/key :app.web-specs/w :app.util/copy])
    """,
    # A spec in the diff.
    "src/app/model.clj" => """
    (ns app.model (:require [clojure.spec.alpha :as s]))

    (s/def ::here int?)
    """,
    "shared/app/both.cljc" => """
    (ns app.both (:require [dep.lib :as lib]))

    (lib/dep-fn 1)
    #?(:cljs (lib/dep-fn 2))
    """,
    # One namespace per platform, both in the diff.
    "src/app/plat.clj" => """
    (ns app.plat)

    (defn now "Clj now." [] 1)
    """,
    "web/app/plat.cljs" => """
    (ns app.plat)

    (defn now "Cljs now." [] 1)
    """,
    "web/app/ui.cljs" => """
    (ns app.ui
      (:require [app.view :as v]
                [dep.lib :as lib]
                [dep.shared :as sh])
      (:require-macros [dep.mac :as m] [dep.both :as b])
      (:require [app.plat :as p]))

    (defn render []
      (v/view-fn) (lib/dep-fn 1) (sh/shared-fn 1) (m/mac 1) (p/now) (b/both-mac 1))
    """
  }

  @jar [
    {"dep/lib.clj", "(ns dep.lib)\n\n(defn dep-fn\n  \"Dep doc.\"\n  [a]\n  a)\n"},
    {"dep/lib.cljs", "(ns dep.lib)\n\n(defn dep-fn \"Dep cljs doc.\" [a] a)\n"},
    {"dep/mac.clj", "(ns dep.mac)\n\n(defmacro mac \"Mac doc.\" [a] a)\n"},
    # A ClojureScript namespace keeping its macros in its .clj file.
    {"dep/both.cljs", "(ns dep.both)\n\n(defn both-fn [a] a)\n"},
    {"dep/both.clj", "(ns dep.both)\n\n(defmacro both-mac \"Both mac doc.\" [a] a)\n"},
    # Read as anything but .cljc, the reader conditional defines nothing.
    {"dep/shared.cljc",
     "(ns dep.shared)\n\n#?(:clj (defn shared-fn \"Shared clj doc.\" [a] a)\n   :cljs (defn shared-fn \"Shared cljs doc.\" [a] a))\n"}
  ]

  # The repo and the dependency directory outside it, built and linted
  # once. The tests share them and one hover server; a test tagged
  # `:own_server` gets its own server, and puts back what it changes.
  setup_all do
    template =
      Meerkat.TestHelpers.fixture_template("meerkat-clj-hover-template", fn template ->
        build_fixture(Path.join(template, "repo"), Path.join(template, "ext"))
      end)

    dir = Path.join(template, "repo")
    {:ok, shared: start(dir)}
  end

  setup ctx do
    if ctx[:own_server], do: start(ctx.shared.dir), else: ctx.shared
  end

  # A hover server for a staged review of `dir`.
  defp start(dir) do
    {:ok, files} = Git.staged_file_diffs(dir)
    rid = "clj-hover-#{System.unique_integer([:positive])}"
    {:ok, pid} = CljHover.ensure_started(rid, dir, files, "HEAD")
    # Stopped before the repo goes: it waits out indexing, which reads the repo.
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{dir: dir, rid: rid, pid: pid, files: files}
  end

  defp build_fixture(dir, ext) do
    File.mkdir_p!(dir)
    git(dir, ["init", "-q", "--initial-branch=main"])

    import_commits(dir, [
      {"refs/heads/main", @base},
      {"refs/meerkat-test/staged",
       @base |> Map.merge(@staged) |> Map.delete("src/app/dropped.clj")}
    ])

    git(dir, ["reset", "-q", "--hard"])
    read_tree(dir, "refs/meerkat-test/staged", nil)
    Enum.each(@staged, fn {path, text} -> write(dir, path, text) end)

    # The worktree differs from the index meerkat reviews, and holds an
    # untracked file beside tracked ones.
    worktree_util = String.replace(@staged["src/app/util.clj"], "New", "Worktree")
    write(dir, "src/app/util.clj", worktree_util <> "\n(defn extra \"Unstaged.\" [] 1)\n")
    write(dir, "src/app/draft.clj", "(ns app.draft)\n\n(defn draft-fn \"Draft doc.\" [] 1)\n")

    jar = Path.join(dir, "libs/dep.jar")
    File.mkdir_p!(Path.dirname(jar))
    entries = for {name, text} <- @jar, do: {String.to_charlist(name), text}
    {:ok, _} = :zip.create(String.to_charlist(jar), entries)
    write(dir, "vendor/vend/tool.clj", "(ns vend.tool)\n\n(defn tool-fn \"Vendor doc.\" [] 1)\n")
    write(dir, "vendor/vend/locked.clj", "(ns vend.locked)\n\n(defn locked-fn [] 1)\n")
    # A dependency's directory outside the repo, as a git dep's is.
    write(ext, "ext/lib.clj", "(ns ext.lib)\n\n(defn ext-fn \"Ext doc.\" [] 1)\n")
    write(dir, ".cpcache/1.cp", "libs/dep.jar:vendor:#{ext}\n")

    # The user's kondo run, as a hook or editor runs it, from the repo
    # root with the default cache. `app.util` is linted last in the
    # diff's file, so its cache names that file.
    File.mkdir_p!(Path.join(dir, ".clj-kondo"))
    {_, _} = System.cmd("clj-kondo", ["--lint", "src", "shared", "web"], cd: dir)
    {_, _} = System.cmd("clj-kondo", ["--lint", "src/app/util.clj"], cd: dir)
    File.chmod!(Path.join(dir, "vendor/vend/locked.clj"), 0)
  end

  # Changes the shared repo's `path` to hold `text`, or removes it for
  # nil, until the test ends.
  defp change(ctx, path, text) do
    file = Path.join(ctx.dir, path)
    before = File.read!(file)
    on_exit(fn -> File.write!(file, before) end)
    if text, do: File.write!(file, text), else: File.rm!(file)
  end

  # Moves HEAD to a commit on it without `path`, until the test ends.
  defp move_head(dir, path) do
    head = git(dir, ["rev-parse", "HEAD"])
    index = Path.join(System.tmp_dir!(), "meerkat-index-#{System.unique_integer([:positive])}")
    env = [{"GIT_INDEX_FILE", index}, {"GIT_AUTHOR_NAME", "t"}, {"GIT_AUTHOR_EMAIL", "t@t.t"}]
    env = env ++ [{"GIT_COMMITTER_NAME", "t"}, {"GIT_COMMITTER_EMAIL", "t@t.t"}]

    run = fn args ->
      {out, 0} = System.cmd("git", args, cd: dir, env: env)
      String.trim(out)
    end

    run.(["read-tree", "HEAD"])
    run.(["rm", "-q", "--cached", path])
    commit = run.(["commit-tree", run.(["write-tree"]), "-p", head, "-m", "move"])
    File.rm!(index)
    run.(["update-ref", "HEAD", commit])
    on_exit(fn -> run.(["update-ref", "HEAD", head]) end)
  end

  defp write(dir, path, text) do
    file = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
    file
  end

  # Hovers the first character of the `nth` `needle` in `file`'s text on `side`.
  defp hover_on(ctx, file, side, needle, nth \\ 1),
    do: on(&CljHover.hover/5, ctx, file, side, needle, nth)

  # Where the symbol at the first character of the `nth` `needle` in
  # `file`'s text on `side` is defined.
  defp definition_on(ctx, file, side, needle, nth \\ 1) do
    case on(&CljHover.definition/5, ctx, file, side, needle, nth) do
      %{to: to} -> to
      other -> other
    end
  end

  defp on(fun, ctx, file, side, needle, nth) do
    index = index(ctx, file)
    text = Map.fetch!(Enum.at(ctx.files, index), :"#{side}_content")
    {line, col} = position(text, needle, nth)
    fun.(ctx.rid, index, side, line, col)
  end

  defp index(ctx, file), do: Enum.find_index(ctx.files, &(&1.file_name == file))

  defp position(text, needle, nth) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, row} ->
      for [{at, _}] <- Regex.scan(~r/#{Regex.escape(needle)}/, line, return: :index),
          do: {row, at + 1}
    end)
    |> Enum.at(nth - 1)
  end

  test "a new row answers from the reviewed index, not the worktree", ctx do
    assert %{name: "app.util/helper", doc: "New doc.", where: "src/app/util.clj", line: 3} =
             hover = hover_on(ctx, "src/app/core.clj", :new, "u/helper")

    assert hover.arglists == ["[x]"]
    assert hover.macro == false
    assert hover.source == "(defn helper\n  \"New doc.\"\n  [x]\n  x)"
  end

  test "a symbol answers across its span and not past it", ctx do
    index = Enum.find_index(ctx.files, &(&1.file_name == "src/app/core.clj"))
    # `  (lib/dep-fn (u/helper (o/thing y))))` on line 13: u/helper is cols 16-23.
    assert %{name: "app.util/helper"} = CljHover.hover(ctx.rid, index, :new, 13, 16)
    assert %{name: "app.util/helper"} = CljHover.hover(ctx.rid, index, :new, 13, 23)
    refute CljHover.hover(ctx.rid, index, :new, 13, 15)
    refute CljHover.hover(ctx.rid, index, :new, 13, 24)
  end

  test "an old row answers from the base", ctx do
    assert %{name: "app.util/helper", doc: "Old doc."} =
             hover_on(ctx, "src/app/core.clj", :old, "u/helper")
  end

  test "vars outside the diff answer from the file kondo's cache names, each kind", ctx do
    assert %{doc: "Other doc.", where: "src/app/other.clj"} =
             hover = hover_on(ctx, "src/app/core.clj", :new, "o/thing")

    assert hover.source == "(defn thing\n  \"Other doc.\"\n  [z]\n  z)"
    assert %{doc: "Common doc."} = hover_on(ctx, "src/app/core.clj", :new, "c/common-fn")
    assert %{doc: "View doc."} = hover_on(ctx, "web/app/ui.cljs", :new, "v/view-fn")
    assert %{doc: "Draft doc."} = hover_on(ctx, "src/app/core.clj", :new, "d/draft-fn")
  end

  test "a diff file answers in the hovering file's language", ctx do
    assert %{doc: "Clj now.", where: "src/app/plat.clj"} =
             hover_on(ctx, "src/app/core.clj", :new, "p/now")

    assert %{doc: "Cljs now.", where: "web/app/plat.cljs"} =
             hover_on(ctx, "web/app/ui.cljs", :new, "p/now")
  end

  describe "go to definition" do
    test "a var in a diff file lands on its line on the symbol's side, with the symbol's span",
         ctx do
      util = index(ctx, "src/app/util.clj")

      # `  (lib/dep-fn (u/helper (o/thing y))))`: u/helper is cols 16-23.
      assert %{col: 16, end_col: 24, to: %{file_index: ^util, side: :new, line: 3}} =
               CljHover.definition(ctx.rid, index(ctx, "src/app/core.clj"), :new, 13, 18)

      assert %{file_index: ^util, side: :old, line: 3} =
               definition_on(ctx, "src/app/core.clj", :old, "u/helper")

      plat = index(ctx, "web/app/plat.cljs")
      assert %{file_index: ^plat, line: 3} = definition_on(ctx, "web/app/ui.cljs", :new, "p/now")
    end

    test "a var outside the diff opens its file view, read as reviewed", ctx do
      assert %{where: "src/app/other.clj", line: 3} =
               definition_on(ctx, "src/app/core.clj", :new, "o/thing")

      assert CljHover.view(ctx.rid, "src/app/other.clj") ==
               %{where: "src/app/other.clj", text: @base["src/app/other.clj"]}

      assert %{where: "dep.jar:dep/lib.clj", line: 3} =
               definition_on(ctx, "src/app/core.clj", :new, "lib/dep-fn")

      assert %{text: "(ns dep.lib)" <> _} = CljHover.view(ctx.rid, "dep.jar:dep/lib.clj")

      assert %{where: "/" <> _, line: 3} =
               definition_on(ctx, "src/app/core.clj", :new, "x/ext-fn")

      # Only a jump opens a view.
      refute CljHover.view(ctx.rid, "src/app/top.clj")
    end

    @tag :own_server
    test "a file view lands on the reviewed text's line, however the worktree differs", ctx do
      change(ctx, "src/app/other.clj", "\n\n" <> @base["src/app/other.clj"])
      assert %{line: 5} = hover_on(ctx, "src/app/core.clj", :new, "o/thing")

      assert %{where: "src/app/other.clj", line: 3} =
               definition_on(ctx, "src/app/core.clj", :new, "o/thing")
    end

    test "a var only the worktree holds has no definition", ctx do
      assert %{doc: "Draft doc."} = hover_on(ctx, "src/app/core.clj", :new, "d/draft-fn")
      refute definition_on(ctx, "src/app/core.clj", :new, "d/draft-fn")
    end

    test "a symbol only the other side's diff files define answers :other_side", ctx do
      assert definition_on(ctx, "src/app/core.clj", :new, "u/gone") == :other_side
      assert definition_on(ctx, "src/app/core.clj", :old, "u/later") == :other_side
      assert definition_on(ctx, "src/app/core.clj", :new, "app.dropped") == :other_side
      assert definition_on(ctx, "src/app/core.clj", :new, ":app.dropped/gone") == :other_side
    end

    test "a local lands on its binding", ctx do
      core = index(ctx, "src/app/core.clj")

      assert %{file_index: ^core, side: :new, line: 12} =
               definition_on(ctx, "src/app/core.clj", :new, "y)")
    end

    test "a namespace lands on its ns form, in the diff or a file view", ctx do
      util = index(ctx, "src/app/util.clj")

      assert %{file_index: ^util, line: 1} =
               definition_on(ctx, "src/app/core.clj", :new, "app.util")

      assert %{where: "src/app/other.clj", line: 1} =
               definition_on(ctx, "src/app/core.clj", :new, "app.other")

      assert %{where: "dep.jar:dep/lib.clj", line: 1} =
               definition_on(ctx, "src/app/core.clj", :new, "dep.lib")
    end

    test "a spec keyword lands on its s/def, in the diff or the repo's other files", ctx do
      model = index(ctx, "src/app/model.clj")

      assert %{file_index: ^model, line: 3} =
               definition_on(ctx, "src/app/core.clj", :new, ":app.model/here")

      assert %{where: "src/app/specs.clj", line: 4} =
               definition_on(ctx, "src/app/core.clj", :new, ":app.specs/id")

      assert %{where: "src/app/specs.clj", line: 5} =
               definition_on(ctx, "src/app/core.clj", :new, ":user/name")

      refute definition_on(ctx, "src/app/core.clj", :new, ":app.specs/nope")

      assert %{where: "web/app/specs.cljs", line: 4} =
               definition_on(ctx, "src/app/core.clj", :new, ":app.web-specs/w")
    end

    test "a spec keyword two files define lands in its own namespace's file", ctx do
      assert %{where: "src/app/my_specs.clj", line: 4} =
               definition_on(ctx, "src/app/core.clj", :new, ":app.my-specs/key")
    end

    test "a spec keyword's search reads only Clojure files with its s/def", ctx do
      assert %{where: "src/app/specs.clj"} =
               definition_on(ctx, "src/app/core.clj", :new, ":user/name")

      for where <- ["README.md", "doc/uses.clj", "doc/names.clj"],
          do: refute(CljHover.view(ctx.rid, where))
    end

    @tag :own_server
    test "a spec keyword's files are searched once per review", ctx do
      assert %{where: "src/app/specs.clj", line: 5} =
               definition_on(ctx, "src/app/core.clj", :new, ":user/name")

      # HEAD, the reviewed ref outside the diff, moves to drop the spec.
      move_head(ctx.dir, "src/app/specs.clj")

      assert %{where: "src/app/specs.clj", line: 5} =
               definition_on(ctx, "src/app/core.clj", :new, ":user/name")
    end

    test "hover and go to definition work in a file view, on the side asked", ctx do
      assert %{where: "src/app/other.clj"} =
               definition_on(ctx, "src/app/core.clj", :new, "o/thing")

      view = {:view, "src/app/other.clj"}
      # `  z)` on line 6 uses the local bound on line 5.
      assert %{to: %{where: "src/app/other.clj", line: 5}} =
               CljHover.definition(ctx.rid, view, :new, 6, 3)

      assert %{name: "app.other/thing"} = CljHover.hover(ctx.rid, view, :new, 3, 7)
      refute CljHover.definition(ctx.rid, {:view, "src/app/nowhere.clj"}, :new, 1, 1)

      # A jar's view names its vars by the jar, as it was opened.
      assert %{where: "dep.jar:dep/lib.clj"} =
               definition_on(ctx, "src/app/core.clj", :new, "lib/dep-fn")

      jar = {:view, "dep.jar:dep/lib.clj"}
      # `(defn dep-fn` on line 3: dep-fn at col 7.
      assert %{name: "dep.lib/dep-fn", where: "dep.jar:dep/lib.clj", in_repo: false} =
               CljHover.hover(ctx.rid, jar, :new, 3, 7)

      assert %{to: %{where: "dep.jar:dep/lib.clj", line: 3}} =
               CljHover.definition(ctx.rid, jar, :new, 3, 7)
    end

    test "in a file view, a diff file's var answers first, then the view's own", ctx do
      assert %{where: "src/app/util_copy.clj", line: 6} =
               definition_on(ctx, "src/app/core.clj", :new, ":app.util/copy")

      copy = {:view, "src/app/util_copy.clj"}
      # `(defn helper` on line 4: helper at col 7.
      assert %{doc: "New doc.", where: "src/app/util.clj"} =
               CljHover.hover(ctx.rid, copy, :new, 4, 7)

      # `(defn copy-fn [] (copy-fn))` on line 8: the call at col 19.
      assert %{to: %{where: "src/app/util_copy.clj", line: 8}} =
               CljHover.definition(ctx.rid, copy, :new, 8, 19)
    end

    test "a blank spot has no definition", ctx do
      refute CljHover.definition(ctx.rid, index(ctx, "src/app/core.clj"), :new, 11, 1)
    end
  end

  test "a .cljc file's :cljs branch answers as ClojureScript", ctx do
    assert %{doc: "Dep doc."} = hover_on(ctx, "shared/app/both.cljc", :new, "lib/dep-fn")

    assert %{doc: "Dep cljs doc."} =
             hover_on(ctx, "shared/app/both.cljc", :new, "lib/dep-fn", 2)
  end

  test "a plain def has no arglists", ctx do
    assert %{name: "app.other/limit", doc: "Limit doc.", arglists: []} =
             hover_on(ctx, "src/app/core.clj", :new, "o/limit")
  end

  test "a var only the worktree's copy of a diff file defines answers nothing", ctx do
    refute hover_on(ctx, "src/app/core.clj", :new, "u/extra")
  end

  @tag :own_server
  test "a namespace is analysed once, keeping the source it was read with", ctx do
    assert %{source: "(ns app.top) (defn" <> _} =
             hover = hover_on(ctx, "src/app/core.clj", :new, "tp/top-fn")

    change(ctx, "src/app/top.clj", nil)
    assert hover_on(ctx, "src/app/core.clj", :new, "tp/top-fn") == hover
  end

  @tag :own_server
  test "a namespace whose cached file is gone, and off the classpath, answers nothing", ctx do
    change(ctx, "src/app/top.clj", nil)
    refute hover_on(ctx, "src/app/core.clj", :new, "tp/top-fn")
  end

  test "dependency vars answer from the classpath, by the hovering file's language", ctx do
    assert %{name: "dep.lib/dep-fn", doc: "Dep doc.", where: "dep.jar:dep/lib.clj", line: 3} =
             hover = hover_on(ctx, "src/app/core.clj", :new, "lib/dep-fn")

    assert hover.source == "(defn dep-fn\n  \"Dep doc.\"\n  [a]\n  a)"
    # Cached: the same answer again.
    assert hover_on(ctx, "src/app/core.clj", :new, "lib/dep-fn") == hover

    assert %{doc: "Dep cljs doc.", where: "dep.jar:dep/lib.cljs"} =
             hover_on(ctx, "web/app/ui.cljs", :new, "lib/dep-fn")

    # A .cljc file answers with the hovering language's reader branch.
    for {file, lang} <- [{"src/app/core.clj", "clj"}, {"web/app/ui.cljs", "cljs"}] do
      doc = "Shared #{lang} doc."

      assert %{doc: ^doc, where: "dep.jar:dep/shared.cljc"} =
               hover_on(ctx, file, :new, "sh/shared-fn")
    end

    # ClojureScript reaches a Clojure namespace for its macros, also
    # past the namespace's own .cljs file.
    assert %{name: "dep.mac/mac", macro: true, doc: "Mac doc."} =
             hover_on(ctx, "web/app/ui.cljs", :new, "m/mac")

    assert %{doc: "Both mac doc.", where: "dep.jar:dep/both.clj"} =
             hover_on(ctx, "web/app/ui.cljs", :new, "b/both-mac")

    assert %{doc: "Vendor doc.", where: "vendor/vend/tool.clj"} =
             hover_on(ctx, "src/app/core.clj", :new, "t/tool-fn")
  end

  @tag :own_server
  test "the classpath is read on the first lookup that needs it, then kept", ctx do
    # Opening the review and hovering a diff file's var leave it unread.
    assert %{name: "app.util/helper"} = hover_on(ctx, "src/app/core.clj", :new, "u/helper")
    change(ctx, ".cpcache/1.cp", "vendor\n")
    refute hover_on(ctx, "src/app/core.clj", :new, "lib/dep-fn")

    File.rm!(Path.join(ctx.dir, ".cpcache/1.cp"))
    assert %{doc: "Vendor doc."} = hover_on(ctx, "src/app/core.clj", :new, "t/tool-fn")
  end

  test "a var is the repo's own only when its file is inside the repo", ctx do
    # A diff file, a file kondo's cache names, and a classpath directory in the repo.
    for needle <- ["u/helper", "o/thing", "t/tool-fn"],
        do: assert(%{in_repo: true} = hover_on(ctx, "src/app/core.clj", :new, needle))

    # A jar, and a classpath directory outside the repo.
    assert %{in_repo: false} = hover_on(ctx, "src/app/core.clj", :new, "lib/dep-fn")

    assert %{in_repo: false, doc: "Ext doc.", where: "/" <> _} =
             hover_on(ctx, "src/app/core.clj", :new, "x/ext-fn")
  end

  test "an unreadable dependency file answers nothing", ctx do
    {hover, log} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        hover_on(ctx, "src/app/core.clj", :new, "l/locked-fn")
      end)

    refute hover
    assert log =~ "couldn't read vend/locked.clj"
  end

  test "a definition's own name answers with itself", ctx do
    assert %{name: "app.util/helper", doc: "New doc."} =
             hover_on(ctx, "src/app/util.clj", :new, "helper")
  end

  test "an old row of a renamed file answers from the file's old name", ctx do
    file = %{
      file_name: "src/app/renamed.clj",
      old_file_name: "src/app/before.clj",
      old_content: "(ns app.before)\n\n(defn gone \"Gone doc.\" [] 1)\n",
      new_content: "(ns app.renamed)\n"
    }

    rid = "clj-hover-#{System.unique_integer([:positive])}"
    {:ok, pid} = CljHover.ensure_started(rid, ctx.dir, [file], "HEAD")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert %{name: "app.before/gone", where: "src/app/before.clj"} =
             CljHover.hover(rid, 0, :old, 3, 7)
  end

  test "hover answers nothing for locals, blank lines and vars off the classpath", ctx do
    # The local y, clojure.core/defn (no Clojure jar on this classpath),
    # and the blank line before `(defn run`.
    refute hover_on(ctx, "src/app/core.clj", :new, "y]")
    refute hover_on(ctx, "src/app/core.clj", :new, "defn")
    index = Enum.find_index(ctx.files, &(&1.file_name == "src/app/core.clj"))
    refute CljHover.hover(ctx.rid, index, :new, 11, 1)
  end

  @tag :own_server
  test "one server per review, not restarted after a crash", ctx do
    assert CljHover.ensure_started(ctx.rid, ctx.dir, ctx.files, "HEAD") == {:ok, ctx.pid}

    # Not restarted: a crash re-indexing in a loop would take its
    # supervisor, and every other review's server, down with it.
    name = {:via, Registry, {Meerkat.ReviewRegistry, {CljHover, ctx.rid}}}
    assert GenServer.whereis(name) == ctx.pid
    ref = Process.monitor(ctx.pid)
    Process.exit(ctx.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    _ = :sys.get_state(Meerkat.ReviewServerSup)
    # The registry drops the dead pid in its own time; whereis skips it.
    refute GenServer.whereis(name)
  end

  test "outside a git repo, hover answers nothing" do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-clj-hover-nogit")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    rid = "clj-hover-nogit-#{System.unique_integer([:positive])}"
    {:ok, pid} = CljHover.ensure_started(rid, dir, [], "HEAD")
    refute CljHover.hover(rid, 0, :new, 1, 1)
    GenServer.stop(pid)
  end

  test "clojure_file? covers .clj, .cljc, .cljs and .edn" do
    for name <- ~w(a.clj b.CLJC c.cljs deps.edn), do: assert(CljHover.clojure_file?(name))
    for name <- ~w(a.ex b.cljx README.md), do: refute(CljHover.clojure_file?(name))
  end
end
