defmodule MeerkatWeb.ConnCase do
  @moduledoc """
  Common test setup for controller / LiveView tests; provides a
  `conn` fixture via `Phoenix.ConnTest`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint MeerkatWeb.Endpoint

      use MeerkatWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import MeerkatWeb.ConnCase
    end
  end

  setup _tags do
    # meerkat binds 127.0.0.1 and MeerkatWeb.Loopback rejects non-loopback
    # Host headers; ConnTest defaults to "www.example.com", so pin the test
    # host to loopback. Tests asserting the guard override this per-request.
    {:ok, conn: %{Phoenix.ConnTest.build_conn() | host: "127.0.0.1"}}
  end
end
