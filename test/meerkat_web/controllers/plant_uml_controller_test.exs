defmodule MeerkatWeb.PlantUMLControllerTest do
  use MeerkatWeb.ConnCase, async: true

  describe "GET /api/plantuml/svg" do
    test "400 when src is missing", %{conn: conn} do
      conn = get(conn, "/api/plantuml/svg")
      assert conn.status == 400
      assert conn.resp_body == "missing src"
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

    # Successful render is exercised in test/meerkat/plant_uml_test.exs;
    # this controller test focuses on the validation paths that don't
    # require a live plantuml binary.
  end
end
