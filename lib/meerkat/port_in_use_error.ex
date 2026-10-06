defmodule Meerkat.PortInUseError do
  # Raised when an explicit nonzero `--port` is taken. It is a rejected
  # argument, not a crash: exit 64 passes straight through both
  # launchers, where exit 2 would make the dev launcher wait for a source
  # change that cannot free the port.
  @moduledoc false
  defexception [:port]

  @impl true
  def message(%{port: port}),
    do: "meerkat: port #{port} is in use (--port #{port}); pick another port or omit --port"
end
