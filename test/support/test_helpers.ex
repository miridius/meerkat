defmodule Meerkat.TestHelpers do
  @moduledoc """
  Shared test helpers. Importable from ExUnit cases without dragging
  in the `ConnCase` setup.
  """

  @doc """
  Build a unique `<tmpdir>/<prefix>-<unique>-<os_time>-<rand>` directory
  with a `.git` subdir so `Meerkat.Git.git_dir/1` resolves under the
  ceiling.

  `unique_integer/1` is monotonic *within* a BEAM lifetime — across
  restarts it can repeat, so a leftover dir from a previous run could
  rehydrate state into the new test. Stamping with `os_time` and a
  random suffix avoids ever aliasing an old one.
  """
  @spec make_tmp_repo(String.t()) :: String.t()
  def make_tmp_repo(prefix \\ "meerkat-test") do
    suffix =
      [
        System.unique_integer([:positive]),
        System.os_time(:nanosecond),
        :rand.uniform(1_000_000)
      ]
      |> Enum.join("-")

    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")
    File.mkdir_p!(Path.join(dir, ".git"))
    dir
  end
end
