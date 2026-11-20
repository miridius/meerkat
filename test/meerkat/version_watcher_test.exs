defmodule Meerkat.VersionWatcherTest do
  # async: false: :restart_fun is global application env.
  use Meerkat.Case, async: false

  alias Meerkat.VersionWatcher

  setup do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-vw")
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

  test "the update topic is meerkat:version" do
    assert VersionWatcher.topic() == "meerkat:version"
  end

  test "init polls every 3 s on Meerkat.PubSub unless told otherwise", %{link: link} do
    assert {:ok, %{link: ^link, poll_ms: 3_000, pubsub: Meerkat.PubSub, viewers: viewers}} =
             VersionWatcher.init(current_link: link)

    assert viewers == (&Meerkat.Viewers.count/0)

    assert {:ok, %{poll_ms: 7, pubsub: :other_pubsub}} =
             VersionWatcher.init(current_link: link, poll_ms: 7, pubsub: :other_pubsub)
  end

  test "a :current_link opt wins over MEERKAT_CURRENT_LINK", %{link: link} do
    Meerkat.TestHelpers.put_env("MEERKAT_CURRENT_LINK", "/no/such/current/link")

    assert {:ok, %{link: ^link}} = VersionWatcher.init(current_link: link)
  end

  test "start_link/0 starts nothing without a current link" do
    Meerkat.TestHelpers.put_env("MEERKAT_CURRENT_LINK", nil)

    assert VersionWatcher.start_link() == :ignore
  end

  test "registers under the :name it is given", %{link: link} do
    pid =
      start_supervised!(
        {VersionWatcher,
         current_link: link, poll_ms: 10, name: :vw_named, viewers_fun: fn -> 1 end}
      )

    assert Process.whereis(:vw_named) == pid
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
    assert_receive {:meerkat_version_available, _}
  end

  test "broadcasts when current flips to a new version", %{dir: dir, link: link} do
    Phoenix.PubSub.subscribe(Meerkat.PubSub, VersionWatcher.topic())
    start(link, viewers_fun: fn -> 1 end)
    flip(link, Path.join(dir, "v2"))

    assert_receive {:meerkat_version_available, target}
    assert Path.basename(target) == "v2"
  end

  test "restarts itself when no viewers are connected, and logs why", %{dir: dir, link: link} do
    test_pid = self()
    Application.put_env(:meerkat, :restart_fun, fn code -> send(test_pid, {:restart, code}) end)
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        start(link, viewers_fun: fn -> 0 end)
        flip(link, Path.join(dir, "v2"))

        assert_receive {:restart, 75}
      end)

    assert log =~
             "Meerkat.VersionWatcher: no viewers connected; restarting onto new version\n"
  end

  test "does not restart while a viewer is connected", %{dir: dir, link: link} do
    test_pid = self()
    Application.put_env(:meerkat, :restart_fun, fn code -> send(test_pid, {:restart, code}) end)
    Phoenix.PubSub.subscribe(Meerkat.PubSub, VersionWatcher.topic())

    start(link, viewers_fun: fn -> 1 end)
    flip(link, Path.join(dir, "v2"))

    assert_receive {:meerkat_version_available, _}
    refute_receive {:restart, _}, 200
  end

  test "re-broadcasts each poll so a viewer that joined after the flip still hears it",
       %{dir: dir, link: link} do
    Phoenix.PubSub.subscribe(Meerkat.PubSub, VersionWatcher.topic())
    start(link, viewers_fun: fn -> 1 end)
    flip(link, Path.join(dir, "v2"))

    assert_receive {:meerkat_version_available, _}
    assert_receive {:meerkat_version_available, _}
  end

  test "stays quiet while current still points at the version it booted", %{link: link} do
    Phoenix.PubSub.subscribe(Meerkat.PubSub, VersionWatcher.topic())
    pid = start(link, viewers_fun: fn -> 1 end)

    send(pid, :poll)
    :sys.get_state(pid)
    refute_received {:meerkat_version_available, _}
  end

  test "keeps watching through a moment with no current link", %{dir: dir, link: link} do
    Phoenix.PubSub.subscribe(Meerkat.PubSub, VersionWatcher.topic())
    pid = start(link, viewers_fun: fn -> 1 end)

    File.rm!(link)
    # Long enough for several polls to find no link.
    Process.sleep(50)
    assert Process.alive?(pid)

    File.ln_s!(Path.join(dir, "v2"), link)
    assert_broadcast_target("v2")
  end

  test "logs a new version once, not on every re-broadcast", %{dir: dir, link: link} do
    Phoenix.PubSub.subscribe(Meerkat.PubSub, VersionWatcher.topic())

    # The test config logs only warnings; the watcher's info lines are the subject.
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        start(link, viewers_fun: fn -> 1 end)
        flip(link, Path.join(dir, "v2"))
        for _ <- 1..3, do: assert_receive({:meerkat_version_available, _})
      end)

    assert [_] = Regex.scan(~r/Meerkat\.VersionWatcher: new version live \(v2\)\n/, log)
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
      ExUnit.configuration()[:assert_receive_timeout] -> flunk("no broadcast for #{expected}")
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
