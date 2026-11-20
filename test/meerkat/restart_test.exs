defmodule Meerkat.RestartTest do
  # Not async: :restart_fun is global application env.
  use Meerkat.Case, async: false

  alias Meerkat.Restart

  test "a restart request exits with the shepherds' respawn code, 75" do
    test_pid = self()
    Application.put_env(:meerkat, :restart_fun, &send(test_pid, {:restart, &1}))
    on_exit(fn -> Application.delete_env(:meerkat, :restart_fun) end)

    Restart.request()

    assert_received {:restart, 75}
    assert Restart.restart_exit_code() == 75
  end
end
