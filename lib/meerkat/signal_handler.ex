defmodule Meerkat.SignalHandler do
  @moduledoc """
  Signal handler for the review BEAM.

  Installed early in `Meerkat.CLI.main/1`, this module replaces OTP's
  `erl_signal_handler` in `erl_signal_server`. OTP's default SIGTERM handling
  stops the system gracefully: before the endpoint starts, that exits 0
  (approved); after, Bandit waits up to 15 seconds for the caller's attach
  stream and the browser's LiveView socket to close. During that wait the
  review cannot deliver a decision; the CLI then exits 2, which the prod
  launcher retries once by respawning the BEAM.

  On SIGTERM, this handler prints
  "meerkat: received SIGTERM — stopping the review, defaulting to REJECT (commit aborted)."
  to stderr, flushes the log file, and halts the VM immediately with exit code
  143. Both launchers propagate 143 without restarting: both restart only on
  75, and `bin/meerkat-shepherd` also retries a first exit 2.

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
    {:ok, state}
  after
    # Halt even if printing raised: gen_event would drop a crashed handler,
    # leaving no handler to act on any later SIGTERM.
    # muex:ignore unreachable I/O seam: halting ends the test VM, so ExUnit cannot run this line; e2e "a SIGTERM to the BEAM ends the review at once and the caller exits 143" in tests/e2e/detach.spec.ts kills these mutants
    System.halt(@exit_code)
  end

  def handle_event(signal, state), do: :erl_signal_handler.handle_event(signal, state)

  @impl true
  def handle_call(request, state), do: :erl_signal_handler.handle_call(request, state)
end
