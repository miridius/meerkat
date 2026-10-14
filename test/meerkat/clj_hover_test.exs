defmodule Meerkat.CljHoverTest do
  # Hover answers on a real staged review, analysed by the real clj-kondo.
  # async: false — the git fixture isolates process-wide git config.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, stage: 3]

  alias Meerkat.{CljHover, Git}

  # Each top-level directory holds one kind of Clojure file, so the
  # worktree pass must find each kind. Only the jar and `vendor` are on
  # the classpath, so project vars can't answer from it.
  @base %{
    "src/app/util.clj" => """
    (ns app.util)

    (defn helper
      "Old doc."
      [x]
      x)
    """,
    "src/app/other.clj" => """
    (ns app.other)

    (defn thing
      "Other doc."
      [z]
      z)

    (def limit "Limit doc." 10)
    """,
    # A namespace split over two files: the diff's file answers.
    "src/app/util_copy.clj" => """
    (ns app.util)

    (defn helper "Copy doc." [x] x)
    """,
    "src/app/core.clj" => """
    (ns app.core
      (:require [app.util :as u]
                [app.other :as o]))

    (defn run [y]
      (u/helper (o/thing y)))
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
                [vend.locked :as l]))

    (defn run [y]
      (lib/dep-fn (u/helper (o/thing y))))

    (defn more []
      (c/common-fn) (d/draft-fn) (sh/shared-fn 1) (t/tool-fn) (l/locked-fn) o/limit (tp/top-fn) (u/extra))
    """,
    "web/app/ui.cljs" => """
    (ns app.ui
      (:require [app.view :as v]
                [dep.lib :as lib]
                [dep.shared :as sh])
      (:require-macros [dep.mac :as m]))

    (defn render []
      (v/view-fn) (lib/dep-fn 1) (sh/shared-fn 1) (m/mac 1))
    """
  }

  @jar [
    {"dep/lib.clj", "(ns dep.lib)\n\n(defn dep-fn\n  \"Dep doc.\"\n  [a]\n  a)\n"},
    {"dep/lib.cljs", "(ns dep.lib)\n\n(defn dep-fn \"Dep cljs doc.\" [a] a)\n"},
    {"dep/mac.clj", "(ns dep.mac)\n\n(defmacro mac \"Mac doc.\" [a] a)\n"},
    # Read as anything but .cljc, the reader conditional defines nothing.
    {"dep/shared.cljc",
     "(ns dep.shared)\n\n#?(:clj (defn shared-fn \"Shared doc.\" [a] a)\n   :cljs (defn shared-fn \"Shared doc.\" [a] a))\n"}
  ]

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    dir = Meerkat.TestHelpers.make_git_repo("meerkat-clj-hover")
    on_exit(fn -> File.rm_rf!(dir) end)
    git(dir, ["config", "user.email", "t@t.t"])
    git(dir, ["config", "user.name", "t"])
    git(dir, ["config", "core.hooksPath", "/dev/null"])

    Enum.each(@base, fn {path, text} -> stage(dir, path, text) end)
    git(dir, ["commit", "-qm", "base"])
    Enum.each(@staged, fn {path, text} -> stage(dir, path, text) end)

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
    locked = write(dir, "vendor/vend/locked.clj", "(ns vend.locked)\n\n(defn locked-fn [] 1)\n")
    File.chmod!(locked, 0)
    write(dir, ".cpcache/1.cp", "libs/dep.jar:vendor\n")

    {:ok, files} = Git.staged_file_diffs(dir)
    rid = "clj-hover-#{System.unique_integer([:positive])}"
    {:ok, pid} = CljHover.ensure_started(rid, dir, files)
    # Stopped before the repo goes: it waits out indexing, which reads the repo.
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{dir: dir, rid: rid, pid: pid, files: files}
  end

  defp write(dir, path, text) do
    file = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
    file
  end

  # Hovers the first character of the `nth` `needle` in `file`'s text on `side`.
  defp hover_on(ctx, file, side, needle, nth \\ 1) do
    index = Enum.find_index(ctx.files, &(&1.file_name == file))
    text = Map.fetch!(Enum.at(ctx.files, index), :"#{side}_content")
    {line, col} = position(text, needle, nth)
    CljHover.hover(ctx.rid, index, side, line, col)
  end

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

  test "vars outside the diff answer from the worktree, each kind of file", ctx do
    assert %{doc: "Other doc.", where: "src/app/other.clj"} =
             hover = hover_on(ctx, "src/app/core.clj", :new, "o/thing")

    assert hover.source == "(defn thing\n  \"Other doc.\"\n  [z]\n  z)"
    assert %{doc: "Common doc."} = hover_on(ctx, "src/app/core.clj", :new, "c/common-fn")
    assert %{doc: "View doc."} = hover_on(ctx, "web/app/ui.cljs", :new, "v/view-fn")
    assert %{doc: "Draft doc."} = hover_on(ctx, "src/app/core.clj", :new, "d/draft-fn")
  end

  test "a plain def has no arglists", ctx do
    assert %{name: "app.other/limit", doc: "Limit doc.", arglists: []} =
             hover_on(ctx, "src/app/core.clj", :new, "o/limit")
  end

  test "a var only the worktree's copy of a diff file defines answers nothing", ctx do
    refute hover_on(ctx, "src/app/core.clj", :new, "u/extra")
  end

  test "a source read after its file is gone is empty", ctx do
    assert %{source: "(ns app.top) (defn" <> _} =
             hover_on(ctx, "src/app/core.clj", :new, "tp/top-fn")

    File.rm!(Path.join(ctx.dir, "src/app/top.clj"))

    assert %{doc: "Top doc.", source: ""} =
             hover_on(ctx, "src/app/core.clj", :new, "tp/top-fn")
  end

  test "dependency vars answer from the classpath, by the hovering file's language", ctx do
    assert %{name: "dep.lib/dep-fn", doc: "Dep doc.", where: "dep.jar:dep/lib.clj", line: 3} =
             hover = hover_on(ctx, "src/app/core.clj", :new, "lib/dep-fn")

    assert hover.source == "(defn dep-fn\n  \"Dep doc.\"\n  [a]\n  a)"
    # Cached: the same answer again.
    assert hover_on(ctx, "src/app/core.clj", :new, "lib/dep-fn") == hover

    assert %{doc: "Dep cljs doc.", where: "dep.jar:dep/lib.cljs"} =
             hover_on(ctx, "web/app/ui.cljs", :new, "lib/dep-fn")

    for file <- ["src/app/core.clj", "web/app/ui.cljs"] do
      assert %{doc: "Shared doc.", where: "dep.jar:dep/shared.cljc"} =
               hover_on(ctx, file, :new, "sh/shared-fn")
    end

    # ClojureScript reaches a Clojure namespace for its macros.
    assert %{name: "dep.mac/mac", macro: true, doc: "Mac doc."} =
             hover_on(ctx, "web/app/ui.cljs", :new, "m/mac")

    assert %{doc: "Vendor doc.", where: "vendor/vend/tool.clj"} =
             hover_on(ctx, "src/app/core.clj", :new, "t/tool-fn")
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

  test "locals, blank lines and vars off the classpath answer nothing", ctx do
    # The local y, clojure.core/defn (no Clojure jar on this classpath),
    # and the blank line before `(defn run`.
    refute hover_on(ctx, "src/app/core.clj", :new, "y]")
    refute hover_on(ctx, "src/app/core.clj", :new, "defn")
    index = Enum.find_index(ctx.files, &(&1.file_name == "src/app/core.clj"))
    refute CljHover.hover(ctx.rid, index, :new, 11, 1)
  end

  test "one server per review, not restarted after a crash", ctx do
    assert CljHover.ensure_started(ctx.rid, ctx.dir, ctx.files) == {:ok, ctx.pid}

    # Not restarted: a crash re-indexing in a loop would take its
    # supervisor, and every other review's server, down with it.
    ref = Process.monitor(ctx.pid)
    Process.exit(ctx.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    _ = :sys.get_state(Meerkat.ReviewServerSup)
    assert Registry.lookup(Meerkat.ReviewRegistry, {CljHover, ctx.rid}) == []
  end

  test "outside a git repo, hover answers nothing" do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-clj-hover-nogit")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    rid = "clj-hover-nogit-#{System.unique_integer([:positive])}"
    {:ok, pid} = CljHover.ensure_started(rid, dir, [])
    refute CljHover.hover(rid, 0, :new, 1, 1)
    GenServer.stop(pid)
  end

  test "clojure_file? covers .clj, .cljc, .cljs and .edn" do
    for name <- ~w(a.clj b.CLJC c.cljs deps.edn), do: assert(CljHover.clojure_file?(name))
    for name <- ~w(a.ex b.cljx README.md), do: refute(CljHover.clojure_file?(name))
  end
end
