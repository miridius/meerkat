defmodule Meerkat.ApplicationTest do
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers, only: [put_env: 2]

  defp put_app_env(key, value) do
    prev = Application.fetch_env(:meerkat, key)
    Application.put_env(:meerkat, key, value)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:meerkat, key, v)
        :error -> Application.delete_env(:meerkat, key)
      end
    end)
  end

  test "the endpoint starts last, after the version watcher and everything its LiveViews use" do
    put_app_env(:start_endpoint, true)
    put_env("MEERKAT_CURRENT_LINK", "/nonexistent/current")

    children = Meerkat.Application.children()

    assert [MeerkatWeb.Telemetry | _] = children
    assert Enum.take(children, -2) == [Meerkat.VersionWatcher, MeerkatWeb.Endpoint]
  end

  test "DNSCluster queries the configured name, or is ignored without one" do
    put_app_env(:dns_cluster_query, nil)
    assert {DNSCluster, query: :ignore} in Meerkat.Application.children()

    put_app_env(:dns_cluster_query, "meerkat.internal")
    assert {DNSCluster, query: "meerkat.internal"} in Meerkat.Application.children()
  end
end
