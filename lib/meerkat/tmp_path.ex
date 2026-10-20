defmodule Meerkat.TmpPath do
  @moduledoc """
  Names for a meerkat's scratch files in the tmp dir.
  """

  @doc """
  A path `<tmp dir>/<prefix>-<OS pid>-<unique>` that no other call in
  a running meerkat returns, without creating it.
  `System.unique_integer/1` is unique only within this BEAM, and every
  meerkat shares the tmp dir, so the OS pid keeps concurrent meerkats
  off each other's files.
  """
  @spec unique(String.t()) :: Path.t()
  def unique(prefix),
    do:
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )
end
