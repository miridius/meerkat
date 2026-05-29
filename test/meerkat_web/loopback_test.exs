defmodule MeerkatWeb.LoopbackTest do
  use MeerkatWeb.ConnCase, async: true

  alias MeerkatWeb.Loopback

  describe "origin?/1" do
    test "accepts loopback hosts" do
      for host <- ~w(127.0.0.1 localhost ::1) do
        assert Loopback.origin?(%URI{host: host})
      end
    end

    test "rejects non-loopback and missing hosts" do
      for host <- ["evil.example.com", "169.254.169.254", "0.0.0.0", "meerkat.test", nil] do
        refute Loopback.origin?(%URI{host: host})
      end
    end
  end

  describe "call/2" do
    test "passes a loopback request through untouched", %{conn: conn} do
      out = Loopback.call(conn, Loopback.init([]))
      refute out.halted
    end

    test "halts a non-loopback request with 403", %{conn: conn} do
      out = %{conn | host: "evil.example.com"} |> Loopback.call(Loopback.init([]))
      assert out.halted
      assert out.status == 403
    end
  end

  describe "pipeline integration" do
    test "non-loopback Host is rejected before the /api/file controller runs", %{conn: conn} do
      conn =
        %{conn | host: "evil.example.com"}
        |> get("/api/file?review_id=x&file_index=0&side=new")

      assert conn.status == 403
    end

    test "non-loopback Host is rejected on the LiveView route", %{conn: conn} do
      conn = get(%{conn | host: "attacker.test"}, "/")
      assert conn.status == 403
    end
  end
end
