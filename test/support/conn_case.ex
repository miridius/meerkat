defmodule MeerkatWeb.ConnCase do
  @moduledoc """
  Common test setup for controller / LiveView tests; provides a
  `conn` fixture via `Phoenix.ConnTest`. Synchronous tests also get
  `Meerkat.Case`'s global-state isolation.
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

  setup tags do
    Meerkat.Case.isolate_global_state(tags)

    # meerkat binds 127.0.0.1 and MeerkatWeb.Loopback rejects non-loopback
    # Host headers; ConnTest defaults to "www.example.com", so pin the test
    # host to loopback. Tests asserting the guard override this per-request.
    {:ok, conn: %{Phoenix.ConnTest.build_conn() | host: "127.0.0.1"}}
  end

  @doc """
  Merges `changes` into the endpoint's config for the calling test and
  restores the old config when it exits. The config is global, so only a
  synchronous test may call it.
  """
  def put_endpoint_config(changes) do
    # Phoenix also caches values in this table as 3-tuples; only the
    # 2-tuples are config.
    old =
      for {key, _} = entry <- :ets.tab2list(MeerkatWeb.Endpoint), key != :__config__, do: entry

    new = Enum.reject(old, fn {key, _} -> List.keymember?(changes, key, 0) end) ++ changes
    MeerkatWeb.Endpoint.config_change([{MeerkatWeb.Endpoint, new}], [])
    on_exit(fn -> MeerkatWeb.Endpoint.config_change([{MeerkatWeb.Endpoint, old}], []) end)
  end
end
