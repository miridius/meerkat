defmodule Meerkat.Restart do
  @moduledoc """
  Halt the BEAM with the shepherd's restart code so the prod shepherd
  respawns it onto the `current` version. Both `Meerkat.VersionWatcher`
  and the review LiveView call this when it's safe to live-restart.

  Indirected through application env (`:restart_fun`) so tests capture
  the request instead of taking the test VM down.
  """

  # The prod and dev shepherds read 75 as "respawn on the same port".
  # Outside the CLI's 0/1/2 decision codes, so a real decision never
  # collides with it.
  @restart_exit_code 75

  @doc "Request a live restart onto the current version."
  @spec request() :: no_return() | any()
  def request do
    fun = Application.get_env(:meerkat, :restart_fun, &System.halt/1)
    fun.(@restart_exit_code)
  end

  @doc false
  def restart_exit_code, do: @restart_exit_code
end
