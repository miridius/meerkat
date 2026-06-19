defmodule Meerkat.VersionWatcherTest do
  # async: false — :restart_fun is global application env.
  use ExUnit.Case, async: false

  alias Meerkat.VersionWatcher

  setup do
    dir = Path.join(System.tmp_dir!(), "meerkat-vw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "v1"))
    File.mkdir_p!(Path.join(dir, "v2"))
    link = Path.join(dir, "current")
    File.ln_s!(Path.join(dir, "v1"), link)

    prev = Application.fetch_env(:meerkat, :restart_fun)

    on_exit(fn ->
      File.rm_rf!(dir)

      case prev do
        {:ok, val} -> Application.put_env(:meerkat, :restart_fun, val)
        :error -> Application.delete_env(:meerkat, :restart_fun)
      end
    end)

    {:ok, dir: dir, link: link}
  end

  defp flip(link, target) do
    File.rm!(link)
    File.ln_s!(target, link)
  end

  defp start(link, opts) do
    name = :"vw_#{System.unique_integer([:positive])}"
    start_supervised!({VersionWatcher, [current_link: link, poll_ms: 10, name: name] ++ opts})
  end

  test "init returns :ignore without a readable current link" do
    assert :ignore == VersionWatcher.init(current_link: nil)
    assert :ignore == VersionWatcher.init(current_link: "/no/such/current/link")
  end

  test "broadcasts when current flips to a new version", %{dir: dir, link: link} do
    Phoenix.PubSub.subscribe(Meerkat.PubSub, VersionWatcher.topic())
    start(link, viewers_fun: fn -> 1 end)
    flip(link, Path.join(dir, "v2"))

    assert_receive {:meerkat_version_available, target}, 1000
    assert Path.basename(target) == "v2"
  end

  test "restarts itself when no viewers are connected", %{dir: dir, link: link} do
    test_pid = self()
    Application.put_env(:meerkat, :restart_fun, fn code -> send(test_pid, {:restart, code}) end)

    start(link, viewers_fun: fn -> 0 end)
    flip(link, Path.join(dir, "v2"))

    assert_receive {:restart, 75}, 1000
  end

  test "does not restart while a viewer is connected", %{dir: dir, link: link} do
    test_pid = self()
    Application.put_env(:meerkat, :restart_fun, fn code -> send(test_pid, {:restart, code}) end)
    Phoenix.PubSub.subscribe(Meerkat.PubSub, VersionWatcher.topic())

    start(link, viewers_fun: fn -> 1 end)
    flip(link, Path.join(dir, "v2"))

    assert_receive {:meerkat_version_available, _}, 1000
    refute_receive {:restart, _}, 200
  end
end
