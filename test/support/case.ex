defmodule Meerkat.Case do
  @moduledoc """
  Case template for every test module; `MeerkatWeb.ConnCase` builds on it.

  A synchronous test starts with no `Meerkat.Decision` and clears any
  decision it leaves. Many synchronous modules reach that singleton, directly
  or through code that reads it (ReviewLive, ReviewServer's saves, the
  watchers).

  A synchronous test fails if it leaves the `:meerkat` application env, the
  OS environment or the working directory changed. Without that check, a
  leak broke only whichever test happened to run next in the same BEAM. That
  happened only in some orders, so it passed in one run and failed in another.

  An async test runs alongside others, so it must not touch any of this
  state, and the template leaves it alone.
  """

  use ExUnit.CaseTemplate

  setup tags do
    isolate_global_state(tags)
  end

  @doc """
  Clears the decision now and again when the test exits, then fails the
  test if the global state it began with was not restored. Does nothing in
  an async test.
  """
  def isolate_global_state(%{async: true}), do: :ok

  def isolate_global_state(_tags) do
    Meerkat.Decision.reset()
    before = global_state()

    # Registered before any setup in the test module, so it runs after all
    # of their on_exit callbacks.
    on_exit(fn ->
      Meerkat.Decision.reset()

      case changes(before, global_state()) do
        [] ->
          :ok

        changes ->
          raise ExUnit.AssertionError,
            message:
              "test left global state changed; restore it in on_exit:\n" <>
                Enum.map_join(changes, "\n", &"  #{&1}")
      end
    end)
  end

  # Decision's deadline sets :review_deadline_ms to nil when it disarms, so a
  # nil value counts as unset.
  @doc false
  def global_state do
    %{
      app_env:
        :meerkat |> Application.get_all_env() |> Map.new() |> Map.reject(&is_nil(elem(&1, 1))),
      os_env: System.get_env(),
      cwd: File.cwd!()
    }
  end

  # Names only: an OS environment value can be a secret.
  @doc false
  def changes(before, now) do
    changed_keys(before.app_env, now.app_env, "application env :meerkat key") ++
      changed_keys(before.os_env, now.os_env, "OS environment variable") ++
      if(before.cwd == now.cwd, do: [], else: ["working directory, now #{now.cwd}"])
  end

  defp changed_keys(before, now, label) do
    for key <- Enum.uniq(Map.keys(before) ++ Map.keys(now)),
        Map.get(before, key) != Map.get(now, key),
        do: "#{label} #{inspect(key)}"
  end
end
