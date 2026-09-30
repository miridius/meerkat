defmodule MeerkatWeb.PlantUMLControllerTest do
  use MeerkatWeb.ConnCase, async: true

  describe "GET /api/plantuml/svg" do
    test "400 when src is missing", %{conn: conn} do
      conn = get(conn, "/api/plantuml/svg")
      assert conn.status == 400
      assert conn.resp_body == "missing src"
    end

    # Over a real socket, with the HTTP options meerkat serves with:
    # the HTTP server's request-line limit is what stood between the
    # client and this guard.
    test "413 when src exceeds the 64 KiB cap, even when every byte is percent-encoded" do
      http = Meerkat.CLI.endpoint_config_for_test(0)[:http]
      server = start_supervised!({Bandit, [plug: MeerkatWeb.Endpoint] ++ http})
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      big = URI.encode_www_form(String.duplicate("é", 32 * 1024 + 1))
      url = ~c"http://127.0.0.1:#{port}/api/plantuml/svg?src=#{big}"

      {:ok, _} = Application.ensure_all_started(:inets)
      assert {:ok, {{_, 413, _}, _, body}} = :httpc.request(:get, {url, []}, [], [])
      assert to_string(body) =~ "src too large"
    end

    # Successful render is exercised in test/meerkat/plant_uml_test.exs;
    # this controller test focuses on the validation paths that don't
    # require a live plantuml binary.
  end
end
