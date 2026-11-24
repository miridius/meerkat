defmodule MeerkatWeb.EndpointTest do
  # Not async: the static-file test writes into priv/static, and the page
  # test sets the review state in the application env.
  use MeerkatWeb.ConnCase, async: false

  import ExUnit.CaptureIO

  @session_options [
    store: :cookie,
    key: "_meerkat_key",
    signing_salt: "Nep9J65z",
    same_site: "Lax"
  ]

  test "serves the static files at the root", %{conn: conn} do
    for path <- ["/robots.txt", "/favicon.svg", "/favicon.ico"] do
      assert conn |> get(path) |> response(200), "#{path} should be served"
    end
  end

  test "serves no file outside the static paths", %{conn: conn} do
    name = "unlisted-#{System.unique_integer([:positive])}.txt"
    path = Application.app_dir(:meerkat, Path.join("priv/static", name))
    File.write!(path, "not public")
    on_exit(fn -> File.rm(path) end)

    conn = get(conn, "/" <> name)
    assert conn.status == 404
    refute conn.resp_body == "not public"
  end

  test "a POST body of a type it cannot parse still reaches the route", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/x-meerkat-test")
      |> post("/api/attach/leave", "raw body")

    assert conn.status == 403
  end

  test "serves a static file's gzipped copy to a client that accepts it", %{conn: conn} do
    gz = Application.app_dir(:meerkat, "priv/static/robots.txt.gz")
    File.write!(gz, :zlib.gzip("gzipped"))
    on_exit(fn -> File.rm(gz) end)

    conn = conn |> put_req_header("accept-encoding", "gzip") |> get("/robots.txt")

    assert get_resp_header(conn, "content-encoding") == ["gzip"]
  end

  test "tags each response with a request id", %{conn: conn} do
    conn = get(conn, "/api/plantuml/svg", src: String.duplicate("a", 64 * 1024 + 1))

    assert [id] = get_resp_header(conn, "x-request-id")
    assert id != ""
  end

  test "reports each request as a Phoenix endpoint telemetry event", %{conn: conn} do
    test_pid = self()
    handler = "endpoint-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:phoenix, :endpoint, :stop],
        fn _, _, %{conn: conn}, _ -> send(test_pid, {:stop, conn.params["probe"]}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    get(conn, "/api/plantuml/svg", src: String.duplicate("a", 64 * 1024 + 1), probe: handler)

    assert_receive {:stop, ^handler}
  end

  test "a request body of a type it cannot parse still reaches the route", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/x-meerkat-test")
      |> get("/api/plantuml/svg", src: String.duplicate("a", 64 * 1024 + 1))

    assert conn.status == 413
  end

  test "accepts a query string of up to 2 MiB", %{conn: conn} do
    limit = 2 * 1024 * 1024
    src = fn length -> "src=" <> String.duplicate("a", length - 4) end

    assert conn |> get("/api/plantuml/svg?" <> src.(limit)) |> response(413)

    assert_raise Plug.Conn.InvalidQueryError, fn ->
      get(conn, "/api/plantuml/svg?" <> src.(limit + 1))
    end
  end

  test "a form's _method field overrides a POST's method", %{conn: conn} do
    assert %{method: "PUT", status: 404} = post(conn, "/", %{"_method" => "PUT"})
  end

  test "an API route answers a client that accepts only HTML, plain text or SVG", %{conn: conn} do
    for accept <- ["text/html", "text/plain", "image/svg+xml"] do
      conn =
        conn
        |> put_req_header("accept", accept)
        |> get("/api/plantuml/svg", src: String.duplicate("a", 64 * 1024 + 1))

      assert conn.status == 413
    end
  end

  test "the page refuses a client that accepts only JSON", %{conn: conn} do
    conn = put_req_header(conn, "accept", "application/json")
    assert_raise Phoenix.NotAcceptableError, fn -> get(conn, "/") end
  end

  test "a HEAD request is answered as the GET it stands for", %{conn: conn} do
    capture_io(:stderr, fn -> send(self(), {:conn, head(conn, "/api/plantuml/svg")}) end)

    assert_received {:conn, %{status: 400}}
  end

  test "the page's session cookie is _meerkat_key, SameSite=Lax and signed with the endpoint's salt",
       %{conn: conn} do
    put_test_vite_manifest()
    Application.put_env(:meerkat, :review_state, %Meerkat.ReviewState{})
    on_exit(fn -> Application.delete_env(:meerkat, :review_state) end)

    conn = get(conn, "/")

    assert %{value: cookie} = conn.resp_cookies["_meerkat_key"]
    assert Enum.any?(get_resp_header(conn, "set-cookie"), &(&1 =~ ~r/SameSite=Lax(;|$)/))

    session =
      build_conn()
      |> Map.put(:secret_key_base, MeerkatWeb.Endpoint.config(:secret_key_base))
      |> put_req_cookie("_meerkat_key", cookie)
      |> Plug.Session.call(Plug.Session.init(@session_options))
      |> fetch_session()
      |> get_session()

    assert session != %{}
  end
end
