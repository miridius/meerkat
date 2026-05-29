defmodule MeerkatWeb.FileContentController do
  @moduledoc """
  `GET /api/file?review_id=…&file_index=…&side=new|old` — return the
  full content of a single file in the review, as `text/plain`, so the
  reviewer can open it in a new browser tab. Content is already loaded
  into `ReviewState` at startup; we just look it up by index.
  """

  use Phoenix.Controller, formats: []

  alias Meerkat.ReviewServer

  def show(conn, %{"review_id" => rid, "file_index" => idx_str, "side" => side})
      when side in ["old", "new"] do
    case Integer.parse(idx_str) do
      {idx, ""} -> send_file_at(conn, rid, idx, side)
      _ -> Plug.Conn.send_resp(conn, 400, "invalid file_index")
    end
  end

  def show(conn, _), do: Plug.Conn.send_resp(conn, 400, "bad request")

  defp send_file_at(conn, rid, idx, side) do
    case fetch_file(rid, idx) do
      :no_review ->
        # The LV that owned this review has exited (BEAM bounce,
        # decision submitted, etc). Tell the caller the review is
        # gone so they don't mistake it for a missing file.
        Plug.Conn.send_resp(conn, 410, "review no longer available")

      :timeout ->
        # GenServer.call hit its timeout — the server is alive but
        # stuck. Distinct from `:no_review` so the user (and any
        # automation) can retry.
        conn
        |> Plug.Conn.put_resp_header("retry-after", "5")
        |> Plug.Conn.send_resp(503, "review server busy; retry")

      {:exit, reason} ->
        # Unexpected exit reason — surface inspect(reason) so the
        # caller can correlate with the stderr log.
        Plug.Conn.send_resp(conn, 500, "review server error: #{inspect(reason)}")

      :not_found ->
        Plug.Conn.send_resp(conn, 404, "file not found")

      {:ok, file} ->
        send_file_content(conn, file, side)
    end
  end

  defp send_file_content(conn, file, side) do
    content =
      case side do
        "old" -> Map.get(file, :old_content) || ""
        "new" -> Map.get(file, :new_content) || ""
      end

    name = Map.get(file, :file_name, "file.txt")

    conn
    |> Plug.Conn.put_resp_content_type("text/plain; charset=utf-8")
    |> Plug.Conn.put_resp_header(
      "content-disposition",
      content_disposition_header(name)
    )
    |> Plug.Conn.send_resp(200, content)
  end

  # RFC 6266 / RFC 5987-aware content-disposition for arbitrary file
  # names. Raw `name` may legally contain `"`, CR, LF, or non-ASCII
  # characters; interpolating any of those into a `filename="..."`
  # quoted-string would break the header (and, with CR/LF, would
  # become a header-injection vector). We provide an ASCII-only
  # `filename` for ancient clients plus an RFC 5987 `filename*` for
  # the real Unicode name.
  defp content_disposition_header(name) do
    base = Path.basename(name)
    ascii_safe = String.replace(base, ~r/[^\w.\-]/u, "_")
    encoded = URI.encode(base, &URI.char_unreserved?/1)
    ~s|inline; filename="#{ascii_safe}"; filename*=UTF-8''#{encoded}|
  end

  defp fetch_file("unbound", _idx), do: :no_review

  defp fetch_file(rid, idx) do
    try do
      ReviewServer.get_file_at(rid, idx)
    catch
      :exit, {:noproc, _} ->
        :no_review

      :exit, {:timeout, _} ->
        IO.puts(
          :stderr,
          "meerkat: FileContentController timed out fetching file #{idx} for review #{rid}"
        )

        :timeout

      :exit, reason ->
        IO.puts(
          :stderr,
          "meerkat: FileContentController couldn't fetch file #{idx} for review #{rid}: " <>
            "#{inspect(reason)}"
        )

        {:exit, reason}
    end
  end
end
