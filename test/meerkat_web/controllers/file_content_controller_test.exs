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
        },
        %{status: :deleted, old_content: "gone"}
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
      # RFC 5987 filename* carries the real percent-encoded name.
      assert get_resp_header(conn, "content-disposition") == [
               ~s|inline; filename="weird_name_with__quotes_.rs"; | <>
                 "filename*=UTF-8''weird%20name%20with%20%22quotes%22.rs"
             ]
    end

    test "404 when file_index is out of bounds", %{conn: conn, review_id: rid} do
      conn = get(conn, "/api/file?review_id=#{rid}&file_index=99&side=new")
      assert conn.status == 404
      assert conn.resp_body == "file not found"
    end

    test "400 when side is neither old nor new", %{conn: conn, review_id: rid} do
      conn = get(conn, "/api/file?review_id=#{rid}&file_index=0&side=bogus")
      assert conn.status == 400
      assert conn.resp_body == "bad request"
    end

    test "410 when review_id is unbound", %{conn: conn} do
      conn = get(conn, "/api/file?review_id=unbound&file_index=0&side=new")
      assert conn.status == 410
      assert conn.resp_body == "review no longer available"
    end

    test "410 for review_id unbound even while a server runs under that id", %{
      conn: conn,
      repo: repo
    } do
      state = %ReviewState{files: [%{file_name: "a.txt", status: :added, new_content: "a"}]}

      {:ok, pid} =
        ReviewServer.ensure_started("unbound", %{repo_path: repo, initial_state: state})

      on_exit(fn -> DynamicSupervisor.terminate_child(Meerkat.ReviewServerSup, pid) end)

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

    test "400 when file_index is not a whole number", %{conn: conn, review_id: rid} do
      conn = get(conn, "/api/file?review_id=#{rid}&file_index=1x&side=new")
      assert conn.status == 400
      assert conn.resp_body == "invalid file_index"
    end

    test "the old side of an added file is empty, not an error", %{conn: conn, review_id: rid} do
      conn = get(conn, "/api/file?review_id=#{rid}&file_index=1&side=old")
      assert conn.status == 200
      assert conn.resp_body == ""
    end

    test "the new side of a deleted file is empty", %{conn: conn, review_id: rid} do
      conn = get(conn, "/api/file?review_id=#{rid}&file_index=2&side=new")
      assert conn.status == 200
      assert conn.resp_body == ""
    end

    test "a file with no name is served as file.txt", %{conn: conn, review_id: rid} do
      conn = get(conn, "/api/file?review_id=#{rid}&file_index=2&side=old")
      assert conn.resp_body == "gone"

      assert get_resp_header(conn, "content-disposition") ==
               [~s|inline; filename="file.txt"; filename*=UTF-8''file.txt|]
    end

    test "is served as UTF-8 plain text, named for download", %{conn: conn, review_id: rid} do
      conn = get(conn, "/api/file?review_id=#{rid}&file_index=0&side=new")
      assert ["text/plain;" <> _] = get_resp_header(conn, "content-type")

      assert get_resp_header(conn, "content-disposition") ==
               [~s|inline; filename="a.txt"; filename*=UTF-8''a.txt|]
    end

    test "503 with a retry-after when the review server times out", %{conn: conn} do
      rid = stuck_review_server(:timeout)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          conn = get(conn, "/api/file?review_id=#{rid}&file_index=0&side=new")
          assert conn.status == 503
          assert conn.resp_body == "review server busy; retry"
          assert get_resp_header(conn, "retry-after") == ["5"]
        end)

      assert stderr ==
               "meerkat: FileContentController timed out fetching file 0 for review #{rid}\n"
    end

    test "500 naming the reason when the review server dies mid-request", %{conn: conn} do
      rid = stuck_review_server(:boom)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          conn = get(conn, "/api/file?review_id=#{rid}&file_index=0&side=new")
          assert conn.status == 500
          assert conn.resp_body =~ ~r/^review server error: \{:boom, /
        end)

      assert stderr =~
               ~r/\Ameerkat: FileContentController couldn't fetch file 0 for review #{rid}: \{:boom, .*\}\n\z/s
    end
  end

  # Registers a stand-in review server that exits with `reason` when
  # called, so the caller sees `GenServer.call` exit with that reason.
  defp stuck_review_server(reason) do
    rid = "fcc-stuck-#{System.unique_integer([:positive])}"
    test = self()

    spawn(fn ->
      {:ok, _} = Registry.register(Meerkat.ReviewRegistry, rid, nil)
      send(test, :registered)

      receive do
        {:"$gen_call", _from, _msg} -> exit(reason)
      end
    end)

    assert_receive :registered
    rid
  end

  defp mk_tmp(prefix), do: Meerkat.TestHelpers.make_tmp_repo(prefix)
end
