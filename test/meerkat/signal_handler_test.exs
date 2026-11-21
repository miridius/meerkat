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
    # A second install must not add a second copy of the handler.
    assert Enum.count(handlers, &(&1 == SignalHandler)) == 1
    refute :erl_signal_handler in handlers
  end

  test "other signals and calls are left to OTP's handling" do
    :ok = SignalHandler.install()

    :ok = :gen_event.sync_notify(:erl_signal_server, :sighup)
    assert :gen_event.call(:erl_signal_server, SignalHandler, :anything) == :ok
    assert SignalHandler in :gen_event.which_handlers(:erl_signal_server)
  end

  test "other signals and calls get OTP's answers with this handler's state" do
    assert SignalHandler.handle_event(:sighup, :state) == {:ok, :state}
    assert SignalHandler.handle_call(:request, :state) == {:ok, :ok, :state}
  end

  test "before halting, a SIGTERM says the review is rejected and writes out the log file" do
    path = Path.join(make_tmp_repo("meerkat-sigterm-log"), "meerkat.log")

    :ok =
      :logger.add_handler(:meerkat_file, :logger_std_h, %{
        config: %{type: {:file, String.to_charlist(path)}},
        formatter: {:logger_formatter, %{}}
      })

    on_exit(fn -> :logger.remove_handler(:meerkat_file) end)
    handler = Process.whereis(:logger_std_h_meerkat_file)
    :sys.suspend(handler)

    announce =
      Task.async(fn ->
        ExUnit.CaptureIO.capture_io(:stderr, &SignalHandler.announce_sigterm/0)
      end)

    try do
      assert eventually(fn ->
               case Process.info(announce.pid, :current_stacktrace) do
                 {:current_stacktrace, stack} ->
                   Enum.any?(stack, &match?({Meerkat.CLI, :flush_logs, 0, _}, &1))

                 nil ->
                   false
               end
             end),
             "the log file is written out before the VM halts"
    after
      :sys.resume(handler)
    end

    assert Task.await(announce) ==
             "meerkat: received SIGTERM — stopping the review, defaulting to REJECT (commit aborted).\n"
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
          # Waits out a slow SIGTERM, below the 180 s test timeout.
          ~s|:io.setopts(:standard_error, encoding: :unicode); | <>
            ~s|Meerkat.SignalHandler.install(); System.cmd("kill", ["-TERM", System.pid()]); | <>
            "Process.sleep(150_000); System.halt(0)"
        ],
        env: [{"MIX_ENV", to_string(Mix.env())}],
        stderr_to_stdout: true
      )

    assert code == 143

    assert output =~
             "meerkat: received SIGTERM — stopping the review, defaulting to REJECT (commit aborted)."
  end
end
