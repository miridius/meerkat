defmodule Meerkat.Settings do
  @moduledoc """
  The review page's toolbar settings: Split / Unified, Wrap, font
  size, tab size and rulers. They live in `settings.json` in meerkat's
  config dir, so every review shares them, and each change is
  broadcast on `topic/0` to the other tabs of this BEAM's review.
  Other running reviews read the file when their tabs next mount.
  """

  @defaults %{
    diff_mode: "split",
    # Wrap long lines by default — horizontal scrolling forces the
    # reviewer off the keyboard and hides context. The toolbar toggle
    # still lets users opt out for code that genuinely reads better
    # unwrapped (long URLs, hex dumps).
    wrap_lines: true,
    font_size_px: 13,
    tab_size: 2,
    rulers: true,
    ruler_columns: [80, 110]
  }

  # muex:ignore equivalent: every subscriber and broadcast names the topic through topic/0
  @topic "meerkat:settings"

  @doc "The settings a missing file or an invalid value falls back to."
  def defaults, do: @defaults

  @doc "PubSub topic carrying `{:settings_changed, changed}`."
  def topic, do: @topic

  @doc """
  The settings file: the `:settings_path` app env when set (tests),
  else `settings.json` in `config_dir/2` of the environment.
  """
  def path do
    Application.get_env(:meerkat, :settings_path) ||
      Path.join(
        config_dir(System.get_env("XDG_CONFIG_HOME"), System.user_home!()),
        "settings.json"
      )
  end

  @doc """
  Meerkat's config dir: `meerkat` under `xdg_config_home`, or under
  `~/.config` when that is unset, empty or relative, as the XDG Base
  Directory spec says.
  """
  def config_dir(xdg_config_home, home) do
    if is_binary(xdg_config_home) and Path.type(xdg_config_home) == :absolute,
      do: Path.join(xdg_config_home, "meerkat"),
      else: Path.join([home, ".config", "meerkat"])
  end

  @doc """
  The saved settings, each missing or invalid one at its default. A
  file that cannot be read or parsed prints a warning.
  """
  def load, do: valid(read(path()))

  @doc """
  Saves `key` as `value`, merged into the file's other settings, and
  broadcasts the change to every other subscriber. A failed save
  prints a warning and still broadcasts, so this review's tabs agree.
  """
  def put(key, value) when is_map_key(@defaults, key) do
    path = path()

    # One read-merge-write at a time, so two tabs' changes to different
    # settings both land.
    :global.trans(
      {__MODULE__, self()},
      fn ->
        body =
          path |> read() |> Map.put(Atom.to_string(key), value) |> Jason.encode!(pretty: true)

        case Meerkat.AtomicFile.write(path, body) do
          :ok -> :ok
          {:error, reason} -> warn("couldn't save settings to #{path}: #{inspect(reason)}")
        end
      end,
      [node()]
    )

    Phoenix.PubSub.broadcast_from(
      Meerkat.PubSub,
      self(),
      @topic,
      {:settings_changed, %{key => value}}
    )
  end

  @doc """
  The settings in a decoded `settings.json`; a missing or invalid one
  is at its default.
  """
  def valid(saved),
    do: %{
      diff_mode: valid_diff_mode(saved["diff_mode"]),
      wrap_lines: valid_bool(saved["wrap_lines"], @defaults.wrap_lines),
      font_size_px: valid_font_size(saved["font_size_px"]),
      tab_size: valid_tab_size(saved["tab_size"]),
      rulers: valid_bool(saved["rulers"], @defaults.rulers),
      ruler_columns: valid_ruler_columns(saved["ruler_columns"], @defaults.ruler_columns)
    }

  @doc """
  The font size, clamped to [9, 28]: outside that the diff is
  unreadable or off the screen at typical zoom levels.
  """
  def clamp_font_size(n), do: n |> max(9) |> min(28)

  @doc "`columns` sorted and deduped when each is a whole number from 1 to 999, else `default`."
  def valid_ruler_columns(columns, default) when is_list(columns) do
    if Enum.all?(columns, &ruler_column?/1),
      do: columns |> Enum.uniq() |> Enum.sort(),
      else: default
  end

  def valid_ruler_columns(_, default), do: default

  # The file's settings as a string-keyed map; empty when it is missing,
  # or, with a warning, when it can't be read or isn't a JSON object.
  defp read(path) do
    with {:ok, json} <- File.read(path),
         {:ok, %{} = saved} <- Jason.decode(json) do
      saved
    else
      {:error, :enoent} ->
        %{}

      {:error, %Jason.DecodeError{} = err} ->
        warn("couldn't parse settings at #{path}: #{Exception.message(err)}")

      {:error, reason} ->
        warn("couldn't read settings at #{path}: #{inspect(reason)}")

      {:ok, _not_an_object} ->
        warn("couldn't parse settings at #{path}: not a JSON object")
    end
  end

  defp warn(message) do
    IO.puts(:stderr, "meerkat: warning — #{message}")
    %{}
  end

  # The other mode, "split", is the default.
  defp valid_diff_mode("unified"), do: "unified"
  defp valid_diff_mode(_), do: @defaults.diff_mode

  defp valid_bool(b, _default) when is_boolean(b), do: b
  defp valid_bool(_, default), do: default

  defp valid_font_size(n) when is_integer(n), do: clamp_font_size(n)
  defp valid_font_size(_), do: @defaults.font_size_px

  defp valid_tab_size(n) when n in [2, 4, 8], do: n
  defp valid_tab_size(_), do: @defaults.tab_size

  # muex:ignore equivalent: `n in 999..1` holds for the same integers
  defp ruler_column?(n), do: is_integer(n) and n in 1..999
end
