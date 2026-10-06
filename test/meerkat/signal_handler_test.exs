defmodule Meerkat.SignalHandlerTest do
  # Not async: the signal handler is VM-global.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers

  alias Meerkat.SignalHandler

  setup do
    restore_signal_handler_on_exit()
  end

  test "install replaces OTP's signal handler and is idempotent" do
    assert SignalHandler.install() == :ok
    assert SignalHandler.install() == :ok

    handlers = :gen_event.which_handlers(:erl_signal_server)
    assert SignalHandler in handlers
    refute :erl_signal_handler in handlers
  end

  test "other signals and calls are left to OTP's handling" do
    :ok = SignalHandler.install()

    :ok = :gen_event.sync_notify(:erl_signal_server, :sighup)
    assert :gen_event.call(:erl_signal_server, SignalHandler, :anything) == :ok
    assert SignalHandler in :gen_event.which_handlers(:erl_signal_server)
  end

  test "a SIGTERM halts the VM with 143 and a REJECT message" do
    {output, code} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "--no-compile",
          "-e",
          # As `Meerkat.CLI.main/1` sets it up.
          ~s|:io.setopts(:standard_error, encoding: :unicode); | <>
            ~s|Meerkat.SignalHandler.install(); System.cmd("kill", ["-TERM", System.pid()]); | <>
            "Process.sleep(10_000); System.halt(0)"
        ],
        env: [{"MIX_ENV", to_string(Mix.env())}],
        stderr_to_stdout: true
      )

    assert code == 143

    assert output =~
             "meerkat: received SIGTERM — stopping the review, defaulting to REJECT (commit aborted)."
  end
end
