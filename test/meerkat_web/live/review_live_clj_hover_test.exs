defmodule MeerkatWeb.ReviewLiveCljHoverTest do
  # Which reviews get Clojure hover, the toolbar note without clj-kondo,
  # and the hover event's answer. async: false — mount reads the global
  # review env, and one test swaps PATH.
  use MeerkatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Meerkat.TestHelpers, only: [git: 2, stage: 3]

  alias Meerkat.{CljHover, Git, ReviewState}
  alias MeerkatWeb.ReviewLive

  @note "Clojure hover off: clj-kondo not found"

  # A spec outside the diff, whose file view the tests open.
  @specs """
  (ns app.specs
    (:require [clojure.spec.alpha :as s]))

  (s/def ::id int?)

  (defn h "Doc h." [] 1)

  (h)
  """

  # One staged review that every test only reads.
  setup_all do
    dir = Meerkat.TestHelpers.fixture_template("meerkat-lv-clj", &build_fixture/1)
    {:ok, files} = Git.staged_file_diffs(dir)
    %{dir: dir, files: files}
  end

  setup do
    prev =
      for key <- [:review_state, :review_id, :repo_path] do
        {key, Application.fetch_env(:meerkat, key)}
      end

    on_exit(fn ->
      Enum.each(prev, fn
        {key, {:ok, val}} -> Application.put_env(:meerkat, key, val)
        {key, :error} -> Application.delete_env(:meerkat, key)
      end)
    end)
  end

  defp build_fixture(dir) do
    git(dir, ["init", "-q"])
    git(dir, ["config", "user.email", "t@t.t"])
    git(dir, ["config", "user.name", "t"])
    git(dir, ["config", "core.hooksPath", "/dev/null"])
    stage(dir, "README.md", "old\n")

    stage(
      dir,
      "src/app/core.clj",
      "(ns app.core)\n\n(defn f\n  \"Doc f.\"\n  []\n  1)\n\n(defn gone [] 1)\n"
    )

    stage(dir, "src/app/specs.clj", @specs)
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "README.md", "new\n")
    # `(app.core/gone)` on line 10, `:app.specs/id` on line 11.
    core =
      "(ns app.core)\n\n(defn f\n  \"Doc f.\"\n  []\n  2)\n\n(f)\n\n(app.core/gone)\n:app.specs/id\n"

    stage(dir, "src/app/core.clj", core)
  end

  defp mount(conn, files, rid, dir) do
    Application.put_env(:meerkat, :review_id, rid)
    Application.put_env(:meerkat, :repo_path, dir)
    Application.put_env(:meerkat, :review_state, %ReviewState{files: files, reviewed_ref: "HEAD"})
    {:ok, view, html} = live_isolated(conn, ReviewLive)
    {view, html}
  end

  defp bound_id, do: "lv-clj-#{System.unique_integer([:positive])}"

  defp indexing?(rid), do: Registry.lookup(Meerkat.ReviewRegistry, {CljHover, rid}) != []

  # The DiffViewer props LiveSvelte renders, per file name.
  defp hover_props(html) do
    Regex.scan(~r/&quot;clj_hover&quot;:(true|false)/, html, capture: :all_but_first)
    |> List.flatten()
  end

  test "a bound review turns hover on for its Clojure files only", %{conn: conn} = ctx do
    {view, html} = mount(conn, ctx.files, bound_id(), ctx.dir)
    names = Enum.map(ctx.files, & &1.file_name)
    expected = Enum.map(names, &to_string(&1 == "src/app/core.clj"))
    assert hover_props(html) == expected
    refute html =~ @note
    assert render(view) =~ "src/app/core.clj"
  end

  test "a hover is answered with the var's docs", %{conn: conn} = ctx do
    {view, _html} = mount(conn, ctx.files, bound_id(), ctx.dir)
    idx = Enum.find_index(ctx.files, &(&1.file_name == "src/app/core.clj"))
    # `(f)` on new line 8: f at col 2.
    params = %{"id" => 7, "file_index" => idx, "side" => "new", "line" => 8, "col" => 2}
    render_hook(view, "clj.hover", params)

    assert_push_event(
      view,
      "clj:hover",
      %{id: 7, hover: %{name: "app.core/f", doc: "Doc f."}}
    )

    render_hook(view, "clj.hover", %{params | "id" => 8, "col" => 1})
    assert_push_event(view, "clj:hover", %{id: 8, hover: nil})

    # An old row reads the base, where `(f)` doesn't exist.
    render_hook(view, "clj.hover", %{params | "id" => 9, "side" => "old"})
    assert_push_event(view, "clj:hover", %{id: 9, hover: nil})

    # Its `(defn f` on old line 3: f at col 7.
    render_hook(view, "clj.hover", %{
      params
      | "id" => 10,
        "side" => "old",
        "line" => 3,
        "col" => 7
    })

    assert_push_event(view, "clj:hover", %{id: 10, hover: %{name: "app.core/f"}})
  end

  test "go to definition answers where the symbol is defined, and a file view by name",
       %{conn: conn} = ctx do
    {view, _html} = mount(conn, ctx.files, bound_id(), ctx.dir)
    idx = Enum.find_index(ctx.files, &(&1.file_name == "src/app/core.clj"))
    params = %{"id" => 3, "file_index" => idx, "side" => "new", "line" => 8, "col" => 2}
    render_hook(view, "clj.definition", params)

    assert_push_event(view, "clj:definition", %{
      id: 3,
      jump: %{col: 2, end_col: 3, to: %{file_index: ^idx, side: :new, line: 3}},
      other_side: false
    })

    render_hook(view, "clj.definition", %{params | "id" => 4, "col" => 1})
    assert_push_event(view, "clj:definition", %{id: 4, jump: nil, other_side: false})

    # Only the base defines `gone`.
    render_hook(view, "clj.definition", %{params | "id" => 40, "line" => 10})
    assert_push_event(view, "clj:definition", %{id: 40, jump: nil, other_side: true})

    # A spec keyword opens its file's view, which hover and go to
    # definition then name by `where`.
    render_hook(view, "clj.definition", %{params | "id" => 41, "line" => 11, "col" => 1})
    to = %{where: "src/app/specs.clj", line: 4}
    assert_push_event(view, "clj:definition", %{id: 41, jump: %{to: ^to}})
    render_hook(view, "clj.view", %{"id" => 42, "where" => "src/app/specs.clj"})
    assert_push_event(view, "clj:view", %{id: 42, view: %{text: @specs}})
    in_view = Map.merge(params, %{"id" => 43, "where" => "src/app/specs.clj", "line" => 8})
    render_hook(view, "clj.hover", in_view)
    assert_push_event(view, "clj:hover", %{id: 43, hover: %{name: "app.specs/h"}})

    # A view no jump opened, named instead of a diff file.
    render_hook(view, "clj.definition", Map.put(%{params | "id" => 5}, "where", "a.clj"))
    assert_push_event(view, "clj:definition", %{id: 5, jump: nil})
    render_hook(view, "clj.view", %{"id" => 6, "where" => "a.clj"})
    assert_push_event(view, "clj:view", %{id: 6, view: nil})
  end

  test "a hover whose server is gone is logged and answers nothing", %{conn: conn} = ctx do
    rid = bound_id()
    {view, _html} = mount(conn, ctx.files, rid, ctx.dir)
    [{pid, _}] = Registry.lookup(Meerkat.ReviewRegistry, {CljHover, rid})
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}

    params = %{"id" => 1, "file_index" => 0, "side" => "new", "line" => 1, "col" => 1}

    # Answering nothing closes the popup of the var hovered before.
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        render_hook(view, "clj.hover", params)
        assert_push_event(view, "clj:hover", %{id: 1, hover: nil})
      end)

    assert stderr =~ "Clojure hover failed"
    assert render(view) =~ "src/app/core.clj"
  end

  test "an unbound review has no hover and ignores hover events", %{conn: conn} = ctx do
    {view, html} = mount(conn, ctx.files, "unbound", ctx.dir)
    assert Enum.uniq(hover_props(html)) == ["false"]
    refute html =~ @note
    refute indexing?("unbound")

    render_hook(view, "clj.hover", %{
      "id" => 1,
      "file_index" => 0,
      "side" => "new",
      "line" => 1,
      "col" => 1
    })

    refute_push_event(view, "clj:hover", %{}, 200)
  end

  test "an unbound review ignores go to definition and file view events", %{conn: conn} = ctx do
    {view, _html} = mount(conn, ctx.files, "unbound", ctx.dir)
    params = %{"id" => 1, "file_index" => 0, "side" => "new", "line" => 1, "col" => 1}
    render_hook(view, "clj.definition", params)
    render_hook(view, "clj.view", %{"id" => 2, "where" => "a.clj"})
    # Unbound, the handlers start no lookup, so nothing can be pushed later.
    refute_push_event(view, "clj:definition", %{}, 0)
    refute_push_event(view, "clj:view", %{}, 0)
  end

  defp hide_kondo do
    without_kondo =
      System.get_env("PATH")
      |> String.split(":")
      |> Enum.reject(&File.exists?(Path.join(&1, "clj-kondo")))
      |> Enum.join(":")

    Meerkat.TestHelpers.put_env("PATH", without_kondo)
  end

  test "without clj-kondo the toolbar notes hover is off", %{conn: conn} = ctx do
    hide_kondo()
    rid = bound_id()
    {_view, html} = mount(conn, ctx.files, rid, ctx.dir)
    assert html =~ @note
    assert Enum.uniq(hover_props(html)) == ["false"]
    refute indexing?(rid)
  end

  test "a review without Clojure files has no note even without clj-kondo", %{conn: conn} = ctx do
    hide_kondo()
    files = Enum.reject(ctx.files, &(&1.file_name == "src/app/core.clj"))
    {_view, html} = mount(conn, files, bound_id(), ctx.dir)
    refute html =~ @note
  end

  test "a review without Clojure files starts no index", %{conn: conn} = ctx do
    files = Enum.reject(ctx.files, &(&1.file_name == "src/app/core.clj"))
    rid = bound_id()
    {_view, html} = mount(conn, files, rid, ctx.dir)
    assert Enum.uniq(hover_props(html)) == ["false"]
    refute indexing?(rid)
  end
end
