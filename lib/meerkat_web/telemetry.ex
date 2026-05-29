defmodule MeerkatWeb.Telemetry do
  @moduledoc """
  Supervises the telemetry poller. No metrics reporter is wired
  in — meerkat doesn't emit metrics anywhere; the poller is here
  for future use.
  """

  use Supervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp periodic_measurements, do: []
end
