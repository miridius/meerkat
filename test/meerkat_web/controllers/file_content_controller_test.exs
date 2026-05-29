defmodule MeerkatWeb.FileContentControllerTest do
  use MeerkatWeb.ConnCase, async: true

  alias Meerkat.{ReviewServer, ReviewState}

  setup %{conn: conn} do
    repo = mk_tmp("meerkat-fcc-test")

    review_id = "fcc#{System.unique_integer([:positive])}"

    state = %ReviewState{
      files: [
        %{
          file_name: "a.txt",
          status: :modified,
          old_content: "old body of a",
          new_content: "new body of a"
        },
        %{
          file_name: "weird name with \"quotes\".rs",
          status: :added,
          new_content: "fn main() {}"
        }
      ]
    }

    {:ok, _pid} = ReviewServer.ensure_started(review_id, %{repo_path: repo, initial_state: state})

    on_exit(fn ->
      case Registry.lookup(Meerkat.ReviewRegistry, review_id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Meerkat.ReviewServerSup, pid)
        _ -> :ok
      end

      File.rm_rf!(repo)
    end)

    {:ok, conn: conn, review_id: review_id, repo: repo}
  end

  describe "GET /api/file" do
    test "returns new-side content as text/plain", %{conn: conn, review_id: rid} do
      conn = get(conn, "/api/file?review_id=#{rid}&file_index=0&side=new")
      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"
      assert conn.resp_body == "new body of a"
    end

    test "returns old-side content for modified files", %{conn: conn, review_id: rid} do
      conn = get(conn, "/api/file?review_id=#{rid}&file_index=0&side=old")
      assert conn.status == 200
      assert conn.resp_body == "old body of a"
    end

    test "filename with quotes is sanitised in content-disposition", %{conn: conn, review_id: rid} do
      conn = get(conn, "/api/file?review_id=#{rid}&file_index=1&side=new")
      assert conn.status == 200
      # ASCII-safe filename can't contain raw quotes — the controller
      # replaces them with underscores so the header is well-formed.
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~r/^inline; filename="[^"]*"; filename\*=UTF-8''/
      refute disposition =~ ~r/filename="[^"]*"[^"]*"[^"]*"/
      # RFC 5987 filename* carries the real percent-encoded name.
      assert disposition =~ "filename*=UTF-8''"
    end

    test "404 when file_index is out of bounds", %{conn: conn, review_id: rid} do
      conn = get(conn, "/api/file?review_id=#{rid}&file_index=99&side=new")
      assert conn.status == 404
    end

    test "400 when side is neither old nor new", %{conn: conn, review_id: rid} do
      conn = get(conn, "/api/file?review_id=#{rid}&file_index=0&side=bogus")
      assert conn.status == 400
    end

    test "410 when review_id is unbound", %{conn: conn} do
      conn = get(conn, "/api/file?review_id=unbound&file_index=0&side=new")
      assert conn.status == 410
    end

    test "410 when review_id refers to a server that doesn't exist", %{conn: conn} do
      conn = get(conn, "/api/file?review_id=nonexistent&file_index=0&side=new")
      assert conn.status == 410
    end

    test "400 when required params are missing", %{conn: conn} do
      conn = get(conn, "/api/file")
      assert conn.status == 400
    end
  end

  defp mk_tmp(prefix), do: Meerkat.TestHelpers.make_tmp_repo(prefix)
end
