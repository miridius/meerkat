defmodule MeerkatWeb.PlantUMLControllerTest do
  use MeerkatWeb.ConnCase, async: true

  describe "GET /api/plantuml/svg" do
    test "400 when src is missing", %{conn: conn} do
      conn = get(conn, "/api/plantuml/svg")
      assert conn.status == 400
      assert conn.resp_body == "missing src"
    end

    test "413 when src exceeds the 64 KiB cap", %{conn: conn} do
      # Single-byte chars × 64 KiB + 1.
      big = String.duplicate("a", 65 * 1024)
      conn = get(conn, "/api/plantuml/svg?src=#{URI.encode_www_form(big)}")
      assert conn.status == 413
      assert conn.resp_body =~ "src too large"
    end

    # Successful render is exercised end-to-end via the Playwright suite;
    # this controller test focuses on the validation paths that don't
    # require a live plantuml binary.
  end
end
