if Mix.env() == :dev do
  defmodule Meerkat.DevWatcher do
    @moduledoc """
    Dev-only file watcher. Halts the BEAM with exit code 75 when a
    source file changes under `lib/`, `assets/{css,svelte,js,ts}/`,
    or `config/`. The `bin/meerkat-beam` shepherd loop interprets 75
    as "restart on the same port"; Phoenix LiveView's client
    auto-reconnect picks up the new BEAM transparently, `ReviewServer`
    reloads in-progress state from `Meerkat.Persistence`, the user's
    browser tab stays where it was.

    Only started under `MIX_ENV=dev` when the CLI flips
    `:start_endpoint` on (i.e. the review UI is actually rendering —
    `mix test` paths skip it). The module compiles in every env so
    the supervisor's start logic stays uniform; the body just never
    runs outside dev.

    Debounce — file-system events can fire dozens of times per save
    (editors write temp files, mv-rename, fsync). We collect events
    for `@debounce_ms` after the first, then halt once.
    """

    use GenServer

    require Logger

    @debounce_ms 150

    @doc "Start under the application supervisor (dev only)."
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(_opts) do
      GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
    end

    @impl true
    def init(_) do
      repo_root = repo_root!()

      case start_file_system(repo_root) do
        {:ok, fs_pid} ->
          FileSystem.subscribe(fs_pid)

          Logger.info(
            "Meerkat.DevWatcher watching #{repo_root} (lib/, assets/, config/). " <>
              "Auto-restart on change."
          )

          {:ok, %{fs_pid: fs_pid, repo_root: repo_root, restart_timer: nil}}

        {:error, reason} ->
          Logger.warning(
            "Meerkat.DevWatcher: couldn't start file_system (#{inspect(reason)}); " <>
              "auto-restart on code change disabled."
          )

          :ignore
      end
    end

    @impl true
    def handle_info({:file_event, _pid, {path, events}}, state) do
      path_str = to_string(path)

      if watched?(path_str, state.repo_root) and meaningful_event?(events) do
        Logger.info(
          "Meerkat.DevWatcher: change detected at #{relative(path_str, state.repo_root)}"
        )

        {:noreply, schedule_restart(state)}
      else
        {:noreply, state}
      end
    end

    def handle_info({:file_event, _pid, :stop}, state) do
      Logger.info("Meerkat.DevWatcher: file_system stopped; auto-restart disabled.")
      {:noreply, %{state | fs_pid: nil}}
    end

    def handle_info(:restart_now, state) do
      # Hold off while a decision is in flight, like the prod restart paths,
      # so the BEAM halts with the decision's exit code instead of a restart
      # (75). Clear the timer so a later change re-arms.
      if is_nil(Meerkat.Decision.current()) do
        Logger.info("Meerkat.DevWatcher: change detected; restarting on the same port.")
        Meerkat.Restart.request()
        {:noreply, state}
      else
        {:noreply, %{state | restart_timer: nil}}
      end
    end

    ## Internals

    defp schedule_restart(%{restart_timer: nil} = state) do
      ref = Process.send_after(self(), :restart_now, @debounce_ms)
      %{state | restart_timer: ref}
    end

    defp schedule_restart(state), do: state

    # Resolve the meerkat project root. `File.cwd!/0` doesn't work
    # because `Meerkat.CLI.main/1` cd's into the user's repo before
    # the supervisor starts. `__DIR__` is captured at compile time
    # and points at `lib/meerkat`; the tree root is two levels up.
    @repo_root Path.expand("../..", __DIR__)

    defp repo_root!, do: @repo_root

    defp start_file_system(repo_root) do
      paths = [
        Path.join(repo_root, "lib"),
        Path.join(repo_root, "assets/css"),
        Path.join(repo_root, "assets/svelte"),
        Path.join(repo_root, "assets/js"),
        Path.join(repo_root, "assets/ts"),
        Path.join(repo_root, "config")
      ]

      existing = Enum.filter(paths, &File.dir?/1)

      if existing == [] do
        {:error, :no_watch_paths}
      else
        FileSystem.start_link(dirs: existing, name: __MODULE__.FileSystem)
      end
    end

    defp watched?(path, repo_root) do
      rel = relative(path, repo_root)

      cond do
        String.ends_with?(rel, ".swp") -> false
        String.ends_with?(rel, "~") -> false
        String.contains?(rel, "/.") -> false
        String.starts_with?(rel, "_build/") -> false
        String.starts_with?(rel, "node_modules/") -> false
        String.starts_with?(rel, "priv/static/") -> false
        String.contains?(rel, "/node_modules/") -> false
        true -> ext(rel) in ~w(ex exs heex svelte css js ts mjs cjs)
      end
    end

    # Treat any of the "real change" event kinds as a trigger.
    # Excludes the bare `:attribute` change that some editors emit
    # on save.
    defp meaningful_event?(events) do
      Enum.any?(events, fn e ->
        e in [:created, :modified, :renamed, :removed, :moved_to, :moved_from]
      end)
    end

    defp relative(path, root) do
      case String.split(path, root <> "/", parts: 2) do
        [_, rel] -> rel
        _ -> path
      end
    end

    defp ext(path), do: path |> Path.extname() |> String.trim_leading(".")
  end
end
