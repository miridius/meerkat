defmodule MeerkatWeb.LiveSocketTest do
  # async: false: these tests change the endpoint's global config.
  use MeerkatWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias MeerkatWeb.Endpoint

  # The LiveView socket reads no session cookie, so these guards are what
  # keep another site from driving a review: the origin check, and the
  # signed token a join needs from the page itself. Each runs over a real
  # socket, as a browser's would.

  setup do
    put_endpoint_config(
      check_origin: Meerkat.CLI.endpoint_config_for_test(0)[:check_origin],
      vite_manifest: PhoenixVite.Manifest.parse(~s({"js/app.js": {"file": "assets/app.js"}}))
    )

    server = start_supervised!({Bandit, plug: Endpoint, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, port: port}
  end

  test "a socket opened from a non-loopback origin is refused", %{port: port} do
    log =
      capture_log(fn ->
        assert {"403", _socket} = upgrade(port, "http://evil.example")
      end)

    assert log =~ "Origin of the request: http://evil.example"
    assert {"101", _socket} = upgrade(port, "http://127.0.0.1:#{port}")
  end

  # Long polling answers 200 and puts its status in the body.
  test "a long poll from a non-loopback origin is refused", %{port: port} do
    log =
      capture_log(fn ->
        assert %{"status" => 403} = long_poll(port, "http://evil.example")
      end)

    assert log =~ "Origin of the request: http://evil.example"
    assert %{"status" => 410} = long_poll(port, "http://127.0.0.1:#{port}")
  end

  test "a join without the page's signed token is refused", %{port: port} do
    {"101", forged} = upgrade(port, "http://127.0.0.1:#{port}")
    assert %{"status" => "error"} = join(forged, port, "forged", nil)

    page = get_page(port)
    [_, session] = Regex.run(~r/data-phx-session="([^"]+)"/, page)
    [_, static] = Regex.run(~r/data-phx-static="([^"]+)"/, page)
    [_, id] = Regex.run(~r/id="([^"]+)"[^>]*data-phx-main/, page)

    {"101", signed} = upgrade(port, "http://127.0.0.1:#{port}")
    assert %{"status" => "ok"} = join(signed, port, session, static, id)

    # The page's token only verifies under the secret that signed it.
    put_endpoint_config(secret_key_base: String.duplicate("x", 64))
    {"101", resigned} = upgrade(port, "http://127.0.0.1:#{port}")
    assert %{"status" => "error"} = join(resigned, port, session, static, id)
  end

  defp long_poll(port, origin) do
    response = http_get(port, "/live/longpoll?vsn=2.0.0", "Origin: #{origin}\r\n")
    [_head, body] = String.split(response, "\r\n\r\n", parts: 2)
    JSON.decode!(body)
  end

  defp get_page(port), do: http_get(port, "/", "")

  defp http_get(port, path, headers) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n#{headers}Connection: close\r\n\r\n"
      )

    read_all(socket, "")
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  # Opens a WebSocket to the LiveView socket from `origin`; returns the
  # response's status code and the open TCP socket.
  defp upgrade(port, origin) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, """
      GET /live/websocket?vsn=2.0.0 HTTP/1.1\r
      Host: 127.0.0.1:#{port}\r
      Origin: #{origin}\r
      Upgrade: websocket\r
      Connection: Upgrade\r
      Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
      Sec-WebSocket-Version: 13\r
      \r
      """)

    {:ok, head} = recv_head(socket, "")
    [_, status] = Regex.run(~r/\AHTTP\/1\.1 (\d{3})/, head)
    {status, socket}
  end

  defp recv_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      recv_head(socket, acc <> data)
    end
  end

  # Joins the root LiveView with `session` and `static` tokens and returns
  # the join reply's payload.
  defp join(socket, port, session, static, id \\ "phx-forged") do
    message =
      JSON.encode!([
        "1",
        "1",
        "lv:#{id}",
        "phx_join",
        %{
          "url" => "http://127.0.0.1:#{port}/",
          "params" => %{"_mounts" => 0},
          "session" => session,
          "static" => static
        }
      ])

    :ok = :gen_tcp.send(socket, client_frame(message))
    {:ok, reply} = recv_frame(socket)
    ["1", "1", _topic, "phx_reply", payload] = JSON.decode!(reply)
    payload
  end

  # A masked text frame, as a client must send.
  defp client_frame(text) do
    mask = :crypto.strong_rand_bytes(4)

    masked =
      :crypto.exor(
        text,
        :binary.copy(mask, div(byte_size(text), 4) + 1) |> binary_part(0, byte_size(text))
      )

    len =
      case byte_size(text) do
        n when n < 126 -> <<1::1, n::7>>
        n when n < 65_536 -> <<1::1, 126::7, n::16>>
        n -> <<1::1, 127::7, n::64>>
      end

    <<0x81, len::binary, mask::binary, masked::binary>>
  end

  defp recv_frame(socket) do
    {:ok, <<_fin_op, _mask::1, len7::7>>} = :gen_tcp.recv(socket, 2, 5_000)

    len =
      case len7 do
        126 -> with {:ok, <<n::16>>} <- :gen_tcp.recv(socket, 2, 5_000), do: n
        127 -> with {:ok, <<n::64>>} <- :gen_tcp.recv(socket, 8, 5_000), do: n
        n -> n
      end

    :gen_tcp.recv(socket, len, 5_000)
  end
end
