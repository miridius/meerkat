defmodule Meerkat.SettingsTest do
  # async: false — each test points the `:settings_path` app env, and
  # one the XDG_CONFIG_HOME env var, at its own file.
  use Meerkat.Case, async: false

  import ExUnit.CaptureIO

  alias Meerkat.Settings

  setup do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-settings")
    File.mkdir_p!(dir)
    path = Path.join(dir, "settings.json")
    prev = Application.fetch_env(:meerkat, :settings_path)
    Application.put_env(:meerkat, :settings_path, path)

    on_exit(fn ->
      case prev do
        {:ok, val} -> Application.put_env(:meerkat, :settings_path, val)
        :error -> Application.delete_env(:meerkat, :settings_path)
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir, path: path}
  end

  test "the config dir is meerkat under an absolute XDG_CONFIG_HOME, else under ~/.config" do
    assert Settings.config_dir("/xdg", "/home/u") == "/xdg/meerkat"

    for unset <- [nil, "", "relative/dir"] do
      assert Settings.config_dir(unset, "/home/u") == "/home/u/.config/meerkat", inspect(unset)
    end
  end

  test "without the app env, the file is settings.json in XDG_CONFIG_HOME's meerkat dir", %{
    dir: dir
  } do
    Application.delete_env(:meerkat, :settings_path)
    prev = System.get_env("XDG_CONFIG_HOME")

    on_exit(fn ->
      if prev,
        do: System.put_env("XDG_CONFIG_HOME", prev),
        else: System.delete_env("XDG_CONFIG_HOME")
    end)

    System.put_env("XDG_CONFIG_HOME", dir)
    assert Settings.path() == Path.join([dir, "meerkat", "settings.json"])
  end

  test "a missing file gives the defaults, with no warning", %{path: path} do
    refute File.exists?(path)
    assert capture_io(:stderr, fn -> Settings.load() end) == ""

    assert Settings.load() == %{
             diff_mode: "split",
             wrap_lines: true,
             font_size_px: 13,
             tab_size: 2,
             rulers: true,
             ruler_columns: [80, 110]
           }

    assert Settings.load() == Settings.defaults()
  end

  test "each saved setting is read, sorted and deduped where a list", %{path: path} do
    File.write!(
      path,
      Jason.encode!(%{
        diff_mode: "unified",
        wrap_lines: false,
        font_size_px: 20,
        tab_size: 4,
        rulers: false,
        ruler_columns: [120, 1, 999, 120]
      })
    )

    assert Settings.load() == %{
             diff_mode: "unified",
             wrap_lines: false,
             font_size_px: 20,
             tab_size: 4,
             rulers: false,
             ruler_columns: [1, 120, 999]
           }
  end

  test "an invalid value keeps its default; font sizes clamp into [9, 28]" do
    defaults = Settings.defaults()

    assert Settings.valid(%{"ruler_columns" => []}).ruler_columns == []

    for junk <- [[0], [1000], [80, "110"], [80.5], "80, 110", nil] do
      assert Settings.valid(%{"ruler_columns" => junk}) == defaults, inspect(junk)
    end

    assert Settings.valid(%{
             "diff_mode" => " sideways",
             "wrap_lines" => "yes",
             "font_size_px" => "big",
             "tab_size" => 7,
             "rulers" => "no"
           }) == defaults

    for n <- [1, 3, 7, "4"] do
      assert Settings.valid(%{"tab_size" => n}).tab_size == 2, inspect(n)
    end

    for {px, clamped} <- [{13, 13}, {1, 9}, {-5, 9}, {28, 28}, {99, 28}] do
      assert Settings.valid(%{"font_size_px" => px}).font_size_px == clamped
      assert Settings.clamp_font_size(px) == clamped
    end
  end

  test "a file that can't be read or parsed warns and gives the defaults", %{path: path} do
    for {body, warning} <- [
          {"{not json",
           ~s(couldn't parse settings at #{path}: unexpected byte at position 1: 0x6E \("n"\))},
          {"[1, 2]", "couldn't parse settings at #{path}: not a JSON object"}
        ] do
      File.write!(path, body)
      err = capture_io(:stderr, fn -> assert Settings.load() == Settings.defaults() end)
      assert err == "meerkat: warning — #{warning}\n", body
    end

    File.rm!(path)
    File.mkdir!(path)
    err = capture_io(:stderr, fn -> assert Settings.load() == Settings.defaults() end)
    assert err =~ "meerkat: warning — couldn't read settings at #{path}: :eisdir"
  end

  test "put merges one setting into the file and broadcasts it to other subscribers only",
       %{path: path} do
    File.write!(path, Jason.encode!(%{wrap_lines: false, future_key: 1, tab_size: 4}))
    test_pid = self()

    other =
      spawn_link(fn ->
        Phoenix.PubSub.subscribe(Meerkat.PubSub, Settings.topic())
        send(test_pid, :subscribed)
        receive do: (msg -> send(test_pid, {:other_got, msg}))
      end)

    assert_receive :subscribed
    Phoenix.PubSub.subscribe(Meerkat.PubSub, Settings.topic())

    Settings.put(:tab_size, 8)

    assert_receive {:other_got, {:settings_changed, %{tab_size: 8}}}
    refute_received {:settings_changed, _}

    assert Jason.decode!(File.read!(path)) == %{
             "wrap_lines" => false,
             "future_key" => 1,
             "tab_size" => 8
           }

    assert %{wrap_lines: false, tab_size: 8} = Settings.load()
    refute Process.alive?(other)
  end

  test "put refuses a key that isn't a setting", %{path: path} do
    assert_raise FunctionClauseError, fn -> Settings.put(:future_key, 1) end
    refute File.exists?(path)
  end

  test "put creates the config dir and writes the file for people to read", %{dir: dir} do
    path = Path.join([dir, "new", "meerkat", "settings.json"])
    Application.put_env(:meerkat, :settings_path, path)
    Settings.put(:diff_mode, "unified")
    assert File.read!(path) == ~s({\n  "diff_mode": "unified"\n})
  end

  test "a failed save warns and still broadcasts", %{dir: dir} do
    blocker = Path.join(dir, "file")
    File.write!(blocker, "")
    path = Path.join([blocker, "settings.json"])
    Application.put_env(:meerkat, :settings_path, path)
    test_pid = self()

    spawn_link(fn ->
      Phoenix.PubSub.subscribe(Meerkat.PubSub, Settings.topic())
      send(test_pid, :subscribed)
      receive do: (msg -> send(test_pid, {:other_got, msg}))
    end)

    assert_receive :subscribed

    err = capture_io(:stderr, fn -> Settings.put(:rulers, false) end)

    assert err =~ "meerkat: warning — couldn't save settings to #{path}: :enotdir\n"
    assert_receive {:other_got, {:settings_changed, %{rulers: false}}}
  end
end
