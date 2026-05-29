defmodule MeerkatWeb.PlantUMLController do
  @moduledoc """
  `GET /api/plantuml/svg?src=<urlencoded>` — render the PlantUML
  source as SVG via `Meerkat.PlantUML.render/1` and stream the
  bytes back. The same source always produces the same SVG so the
  Cache-Control header is `immutable` — the URL's `src` already
  varies per diagram.
  """

  use Phoenix.Controller, formats: [:html]

  # PlantUML's CLI takes 30s per render, so a malformed (very long)
  # `src` could tie up the BEAM unnecessarily. 64 KiB covers any
  # realistic diagram source.
  @max_src_bytes 64 * 1024

  def svg(conn, %{"src" => src}) when is_binary(src) do
    cond do
      byte_size(src) > @max_src_bytes ->
        Plug.Conn.send_resp(
          conn,
          413,
          "src too large (#{byte_size(src)} bytes; limit is #{@max_src_bytes})"
        )

      true ->
        render_svg(conn, src)
    end
  end

  def svg(conn, params) do
    IO.puts(
      :stderr,
      "meerkat: PlantUMLController.svg/2 — bad request, missing or non-binary src " <>
        "(params keys: #{inspect(Map.keys(params))})"
    )

    Plug.Conn.send_resp(conn, 400, "missing src")
  end

  defp render_svg(conn, src) do
    case Meerkat.PlantUML.render(src) do
      {:ok, svg} ->
        conn
        # SVG can in principle carry <script>; the response stays on
        # loopback (single-user local app), but a Content-Security-
        # Policy header is cheap defence-in-depth against a future
        # `meerkat --serve` mode.
        |> Plug.Conn.put_resp_content_type("image/svg+xml")
        |> Plug.Conn.put_resp_header("cache-control", "public, max-age=3600, immutable")
        |> Plug.Conn.put_resp_header("content-security-policy", "script-src 'none'")
        |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
        |> Plug.Conn.send_resp(200, svg)

      {:error, reason} ->
        # 422 = unprocessable entity. The dominant failure mode is a
        # user-typed syntax error in the diagram source; 500 would
        # surface as a misleading "Failed to load resource" in
        # devtools. The plain-text content-type lets the front-end's
        # `<img onerror>` → fetch() handler read the stderr reason.
        conn
        |> Plug.Conn.put_resp_content_type("text/plain; charset=utf-8")
        |> Plug.Conn.send_resp(422, reason)
    end
  end
end
