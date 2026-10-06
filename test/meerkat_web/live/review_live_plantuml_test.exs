defmodule MeerkatWeb.ReviewLivePlantUMLTest do
  # Which reviews tell DiffViewer that PlantUML can preview their
  # diagrams, and which never start the probe's JVM. async: false —
  # mount reads the global `:meerkat, :review_state`, and the test swaps
  # PATH and the BEAM-wide cached probe answer.
  use MeerkatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Meerkat.{Decision, PlantUML, ReviewState}

  setup do
    Decision.reset()
    prev_state = Application.get_env(:meerkat, :review_state)
    prev_path = System.get_env("PATH")

    stub_dir =
      Path.join(System.tmp_dir!(), "meerkat-plantuml-lv-#{System.unique_integer([:positive])}")

    File.mkdir_p!(stub_dir)
    :persistent_term.erase({PlantUML, :available?})

    on_exit(fn ->
      System.put_env("PATH", prev_path)
      :persistent_term.erase({PlantUML, :available?})
      File.rm_rf!(stub_dir)

      if prev_state,
        do: Application.put_env(:meerkat, :review_state, prev_state),
        else: Application.delete_env(:meerkat, :review_state)
    end)

    System.put_env("PATH", stub_dir <> ":" <> prev_path)
    %{stub_dir: stub_dir, calls: Path.join(stub_dir, "calls")}
  end

  # A `plantuml` that records each run and exits with `code`.
  defp stub_plantuml(%{stub_dir: dir, calls: calls}, code) do
    path = Path.join(dir, "plantuml")
    File.write!(path, "#!/bin/sh\necho \"$@\" >> '#{calls}'\nexit #{code}\n")
    File.chmod!(path, 0o755)
  end

  defp probed?(%{calls: calls}), do: File.exists?(calls)

  defp file(name) do
    %{
      status: :modified,
      file_name: name,
      old_file_name: nil,
      old_content: "@startuml\nA -> B\n@enduml\n",
      new_content: "@startuml\nA -> C\n@enduml\n",
      hunks: ["@@ -1,3 +1,3 @@\n @startuml\n-A -> B\n+A -> C\n @enduml"],
      read_errors: [],
      effective_oid: "",
      is_generated: false
    }
  end

  defp render_review(conn, names) do
    Application.put_env(:meerkat, :review_state, %ReviewState{files: Enum.map(names, &file/1)})
    {:ok, _view, html} = live_isolated(conn, MeerkatWeb.ReviewLive)
    html
  end

  @available ~s(&quot;plantuml_available&quot;:true)
  @unavailable ~s(&quot;plantuml_available&quot;:false)

  test "a review with a .puml file previews it when plantuml runs", %{conn: conn} = ctx do
    stub_plantuml(ctx, 0)

    html = render_review(conn, ["docs/flow.puml"])
    assert html =~ @available
    refute html =~ @unavailable
  end

  test "a .plantuml file, and an upper-case extension, count as diagrams", %{conn: conn} = ctx do
    stub_plantuml(ctx, 0)

    assert render_review(conn, ["docs/flow.plantuml"]) =~ @available
    assert render_review(conn, ["docs/FLOW.PUML"]) =~ @available
  end

  test "a review with a .puml file shows the install hint when plantuml fails",
       %{conn: conn} = ctx do
    stub_plantuml(ctx, 1)

    html = render_review(conn, ["docs/flow.puml"])
    assert html =~ @unavailable
    refute html =~ @available
  end

  test "a review without a diagram never probes plantuml", %{conn: conn} = ctx do
    stub_plantuml(ctx, 0)

    html = render_review(conn, ["src/widget.rs", "docs/flow.md"])
    assert html =~ @unavailable
    refute probed?(ctx)
  end
end
