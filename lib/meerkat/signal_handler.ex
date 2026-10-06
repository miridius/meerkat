defmodule Meerkat.SignalHandler do
  @moduledoc """
  Signal handler for the review BEAM.

  Installed by `Meerkat.CLI` before the endpoint starts, this module replaces
  OTP's `erl_signal_handler` in `erl_signal_server`. OTP's default SIGTERM
  handling stops the system gracefully, leaving Bandit waiting up to 15 seconds
  for the caller's attach stream and the browser's LiveView socket to close.
  During that wait the review cannot deliver a decision; the CLI then exits 2,
  which the prod launcher retries once by respawning the BEAM.

  On SIGTERM, this handler prints
  "meerkat: received SIGTERM — stopping the review, defaulting to REJECT (commit aborted)."
  to stderr, flushes the log file, and halts the VM immediately with exit code
  143. Both launchers propagate 143 without restarting: `bin/meerkat-beam`
  restarts only on 75, and `bin/meerkat-shepherd` retries only 2.

  Other signals are passed to `erl_signal_handler` unchanged.
  """

  @behaviour :gen_event

  @exit_code 143

  @spec install() :: :ok
  def install do
    if __MODULE__ in :gen_event.which_handlers(:erl_signal_server) do
      :ok
    else
      :ok =
        :gen_event.swap_handler(
          :erl_signal_server,
          {:erl_signal_handler, []},
          {__MODULE__, []}
        )
    end
  end

  @impl true
  def init({[], _erl_signal_handler_result}), do: :erl_signal_handler.init([])

  @impl true
  def handle_event(:sigterm, state) do
    IO.puts(
      :stderr,
      "meerkat: received SIGTERM — stopping the review, defaulting to REJECT (commit aborted)."
    )

    Meerkat.CLI.flush_logs()
    System.halt(@exit_code)
    {:ok, state}
  end

  def handle_event(signal, state), do: :erl_signal_handler.handle_event(signal, state)

  @impl true
  def handle_call(request, state), do: :erl_signal_handler.handle_call(request, state)
end
