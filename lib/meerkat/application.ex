defmodule Meerkat.Application do
  @moduledoc false

  use Application

  # Compile-time env captured here so release builds don't need Mix
  # at runtime to gate the dev-watcher.
  @env Mix.env()

  @impl true
  def start(_type, _args) do
    children =
      [
        MeerkatWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:meerkat, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Meerkat.PubSub},
        # Registry + DynamicSupervisor for `Meerkat.ReviewServer` —
        # one coordinator GenServer per review_id, started lazily on
        # first mount. Single-writer guarantee for review state.
        {Registry, keys: :unique, name: Meerkat.ReviewRegistry},
        # Connected review LiveViews register here so Meerkat.VersionWatcher
        # can tell whether anyone is watching before it live-restarts.
        {Registry, keys: :duplicate, name: Meerkat.ViewerRegistry},
        {DynamicSupervisor, name: Meerkat.ReviewServerSup, strategy: :one_for_one},
        Meerkat.Decision
      ] ++ dev_watcher_child() ++ version_watcher_child() ++ endpoint_child()

    opts = [strategy: :one_for_one, name: Meerkat.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Dev mode only: watch lib/ + assets/ and halt the BEAM with exit
  # code 75 on any change. `bin/meerkat-beam` shepherd loop respawns
  # on the same port; the user's browser tab reconnects to the new
  # BEAM transparently. Gated on @env so the release supervisor
  # never tries to start the watcher.
  defp dev_watcher_child do
    if @env == :dev and Application.get_env(:meerkat, :start_endpoint, false) do
      [Meerkat.DevWatcher]
    else
      []
    end
  end

  # Prod analogue: watch the install's `current` symlink and live-restart
  # onto a newly-installed version. Gated on MEERKAT_CURRENT_LINK (set by
  # the shepherd), so it only starts under a versioned prod install.
  defp version_watcher_child do
    if Application.get_env(:meerkat, :start_endpoint, false) and
         System.get_env("MEERKAT_CURRENT_LINK") do
      [Meerkat.VersionWatcher]
    else
      []
    end
  end

  # The CLI sets :meerkat, :start_endpoint to true once it has decided
  # the review UI is needed (i.e. the staged diff is non-empty).
  # `mix test` and other non-CLI entry points keep the endpoint off
  # unless explicitly requested via :endpoint config.
  defp endpoint_child do
    cond do
      Application.get_env(:meerkat, :start_endpoint, false) -> [MeerkatWeb.Endpoint]
      Application.get_env(:meerkat, MeerkatWeb.Endpoint)[:server] -> [MeerkatWeb.Endpoint]
      true -> []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    MeerkatWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
