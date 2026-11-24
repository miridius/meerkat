defmodule MeerkatWeb.PlantUMLControllerTest do
  # Not async: the render tests put a fake plantuml on the global PATH.
  use MeerkatWeb.ConnCase, async: false

  describe "GET /api/plantuml/svg" do
    test "400 when src is missing, naming the params it got on stderr", %{conn: conn} do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          conn = get(conn, "/api/plantuml/svg", other: "x")
          assert conn.status == 400
          assert conn.resp_body == "missing src"
        end)

      assert stderr ==
               "meerkat: PlantUMLController.svg/2 — bad request, missing or non-binary src " <>
                 ~s|(params keys: ["other"])\n|
    end

    # Over a real socket, with the HTTP options meerkat serves with: the
    # HTTP server's request-line limit and the query-string limit must
    # both let these through to the guard.
    test "413 for a src over the 64 KiB cap, well into the size a browser will request" do
      http = Meerkat.CLI.endpoint_config_for_test(0)[:http]
      server = start_supervised!({Bandit, [plug: MeerkatWeb.Endpoint] ++ http})
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      {:ok, _} = Application.ensure_all_started(:inets)

      # Two-byte chars, each byte percent-encoding to three: 70 KiB
      # encodes to ~215K chars, 340 KiB to ~1.04M, both under Chrome's
      # 2 MiB URL limit.
      for kib <- [70, 340] do
        big = URI.encode_www_form(String.duplicate("é", div(kib * 1024, 2)))
        url = ~c"http://127.0.0.1:#{port}/api/plantuml/svg?src=#{big}"

        assert {:ok, {{_, 413, _}, _, body}} = :httpc.request(:get, {url, []}, [], [])
        assert to_string(body) =~ "src too large"
      end
    end

    test "a src one byte over the cap is refused, naming its size and the limit", %{conn: conn} do
      conn = get(conn, "/api/plantuml/svg", src: String.duplicate("a", 64 * 1024 + 1))

      assert conn.status == 413
      assert conn.resp_body == "src too large (65537 bytes; limit is 65536)"
    end
  end

  describe "GET /api/plantuml/svg with plantuml installed" do
    # A `plantuml` on PATH that echoes its stdin back as the "SVG", or
    # fails with a diagnosis for a source containing "bad".
    setup do
      dir = Meerkat.TestHelpers.tmp_path("meerkat-plantuml-controller")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "plantuml"), """
      #!/bin/sh
      src=$(cat)
      case "$src" in
        *bad*) echo "Syntax Error?" >&2; exit 1 ;;
        *) printf '<svg>%s</svg>' "$src" ;;
      esac
      """)

      File.chmod!(Path.join(dir, "plantuml"), 0o755)
      Meerkat.TestHelpers.put_env("PATH", dir <> ":" <> System.fetch_env!("PATH"))
      on_exit(fn -> File.rm_rf!(dir) end)
    end

    test "serves the rendered SVG as an immutable, script-free image", %{conn: conn} do
      conn = get(conn, "/api/plantuml/svg", src: "A -> B")

      assert conn.status == 200
      assert conn.resp_body == "<svg>A -> B</svg>"
      assert get_resp_header(conn, "content-type") == ["image/svg+xml; charset=utf-8"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600, immutable"]
      assert get_resp_header(conn, "content-security-policy") == ["script-src 'none'"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "a request accepting only SVG is served", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "image/svg+xml")
        |> get("/api/plantuml/svg", src: "A -> B")

      assert conn.status == 200
    end

    test "a src exactly at the cap is rendered", %{conn: conn} do
      src = String.duplicate("a", 64 * 1024)
      conn = get(conn, "/api/plantuml/svg", src: src)

      assert conn.status == 200
      assert conn.resp_body == "<svg>#{src}</svg>"
    end

    test "a diagram plantuml rejects is a 422 carrying its diagnosis", %{conn: conn} do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        conn = get(conn, "/api/plantuml/svg", src: "bad diagram")

        assert conn.status == 422
        assert conn.resp_body =~ "Syntax Error?"
        assert ["text/plain;" <> params] = get_resp_header(conn, "content-type")

        assert params |> String.split(";") |> Enum.map(&String.trim/1) |> Enum.uniq() == [
                 "charset=utf-8"
               ]
      end)
    end
  end
end
