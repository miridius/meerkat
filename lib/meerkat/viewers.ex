defmodule Meerkat.Viewers do
  @moduledoc """
  Tracks connected review LiveViews in a duplicate-key Registry so
  `Meerkat.VersionWatcher` can tell whether anyone is watching. A LiveView
  registers on connected mount and is removed automatically when it exits.
  """

  @registry Meerkat.ViewerRegistry

  @doc "Register the calling LiveView process as a connected viewer."
  @spec register() :: {:ok, pid()} | {:error, term()}
  def register, do: Registry.register(@registry, :viewer, nil)

  @doc "How many review LiveViews are currently connected."
  @spec count() :: non_neg_integer()
  def count, do: Registry.count(@registry)
end
