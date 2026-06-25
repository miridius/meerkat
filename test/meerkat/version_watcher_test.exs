defmodule Meerkat.VersionWatcherTest do
  # async: false: :restart_fun is global application env.
  use ExUnit.Case, async: false

  alias Meerkat.VersionWatcher

  setup do
    # The :pending no-viewer restart is gated on no decision being in
    # flight; reset the global singleton so a prior test's decision can't
    # block it.
    Meerkat.Decision.reset()

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

  test "falls back to MEERKAT_CURRENT_LINK when no :current_link opt is given",
       %{dir: dir, link: link} do
    prev = System.get_env("MEERKAT_CURRENT_LINK")
    System.put_env("MEERKAT_CURRENT_LINK", link)

    on_exit(fn ->
      if prev,
        do: System.put_env("MEERKAT_CURRENT_LINK", prev),
        else: System.delete_env("MEERKAT_CURRENT_LINK")
    end)

    Phoenix.PubSub.subscribe(Meerkat.PubSub, VersionWatcher.topic())
    name = :"vw_env_#{System.unique_integer([:positive])}"
    start_supervised!({VersionWatcher, [poll_ms: 10, name: name, viewers_fun: fn -> 1 end]})

    flip(link, Path.join(dir, "v2"))
    assert_receive {:meerkat_version_available, _}, 1000
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

  test "re-broadcasts each poll so a viewer that joined after the flip still hears it",
       %{dir: dir, link: link} do
    Phoenix.PubSub.subscribe(Meerkat.PubSub, VersionWatcher.topic())
    start(link, viewers_fun: fn -> 1 end)
    flip(link, Path.join(dir, "v2"))

    assert_receive {:meerkat_version_available, _}, 1000
    assert_receive {:meerkat_version_available, _}, 1000
  end

  test "broadcasts the new target after a second flip", %{dir: dir, link: link} do
    File.mkdir_p!(Path.join(dir, "v3"))
    Phoenix.PubSub.subscribe(Meerkat.PubSub, VersionWatcher.topic())
    start(link, viewers_fun: fn -> 1 end)

    flip(link, Path.join(dir, "v2"))
    assert_broadcast_target("v2")

    flip(link, Path.join(dir, "v3"))
    assert_broadcast_target("v3")
  end

  # Drain re-broadcasts of earlier targets until the expected one arrives.
  defp assert_broadcast_target(expected) do
    receive do
      {:meerkat_version_available, target} ->
        if Path.basename(target) == expected,
          do: :ok,
          else: assert_broadcast_target(expected)
    after
      1000 -> flunk("no broadcast for #{expected}")
    end
  end

  test "does not restart while a decision is in flight, even with no viewers",
       %{dir: dir, link: link} do
    test_pid = self()
    Application.put_env(:meerkat, :restart_fun, fn code -> send(test_pid, {:restart, code}) end)
    Meerkat.Decision.submit({:approve, ""})

    start(link, viewers_fun: fn -> 0 end)
    flip(link, Path.join(dir, "v2"))

    refute_receive {:restart, _}, 200
  end
end
