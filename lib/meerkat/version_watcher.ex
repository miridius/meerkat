defmodule Meerkat.VersionWatcher do
  @moduledoc """
  Prod analogue of `Meerkat.DevWatcher`. Polls the install's `current`
  symlink (path from `MEERKAT_CURRENT_LINK`); when it points at a version
  other than the one this BEAM booted from, a newer release is live.

  It broadcasts `{:meerkat_version_available, target}` on `topic/0` so
  connected review LiveViews reload at a safe point (no open comment
  form). With no LiveView connected it calls `Meerkat.Restart.request/0`
  itself. Either way the shepherd respawns onto the new version and
  `ReviewServer` reloads the in-progress snapshot.

  `init/1` returns `:ignore` when `MEERKAT_CURRENT_LINK` is unset or
  unreadable (dev, tests, an ad-hoc run from a non-symlinked install), so
  the watcher only does anything under a versioned prod install.
  """

  use GenServer
  require Logger

  @poll_ms 3_000
  @topic "meerkat:version"

  @doc "PubSub topic carrying `{:meerkat_version_available, target}`."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Start the watcher. Options (all defaulted, overridable for tests):
  `:current_link`, `:poll_ms`, `:pubsub`, `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    link = Keyword.get(opts, :current_link) || System.get_env("MEERKAT_CURRENT_LINK")

    case link && File.read_link(link) do
      {:ok, boot} ->
        poll_ms = Keyword.get(opts, :poll_ms, @poll_ms)
        Process.send_after(self(), :poll, poll_ms)

        {:ok,
         %{
           link: link,
           boot: boot,
           poll_ms: poll_ms,
           pubsub: Keyword.get(opts, :pubsub, Meerkat.PubSub),
           viewers: Keyword.get(opts, :viewers_fun, &Meerkat.Viewers.count/0),
           notified: nil
         }}

      _ ->
        :ignore
    end
  end

  @impl true
  def handle_info(:poll, state) do
    case File.read_link(state.link) do
      {:ok, target} when target != state.boot ->
        {:noreply, handle_update(broadcast(state, target))}

      _ ->
        {:noreply, schedule(state)}
    end
  end

  # Re-broadcast every poll while an update is outstanding, rather than
  # only on first detection, so a tab that connects after the flip, and a
  # further flip, both get signalled; the LiveView treats repeats as
  # idempotent. Only log on a target change to avoid per-poll spam.
  defp broadcast(state, target) do
    if state.notified != target do
      Logger.info("Meerkat.VersionWatcher: new version live (#{Path.basename(target)})")
    end

    Phoenix.PubSub.broadcast(state.pubsub, @topic, {:meerkat_version_available, target})
    %{state | notified: target}
  end

  # Connected LiveViews reload themselves once they're at a safe point;
  # only restart from here when none are connected (or once they've all
  # disconnected without reloading), so a reviewer mid-comment is never
  # interrupted. Skip it too once a decision is in flight: the CLI is about
  # to halt with the decision's exit code and a restart (75) would preempt
  # and lose it.
  defp handle_update(state) do
    if state.viewers.() == 0 and is_nil(Meerkat.Decision.current()) do
      Logger.info("Meerkat.VersionWatcher: no viewers connected; restarting onto new version")
      Meerkat.Restart.request()
      state
    else
      schedule(state)
    end
  end

  defp schedule(state) do
    Process.send_after(self(), :poll, state.poll_ms)
    state
  end
end
