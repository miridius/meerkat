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

  # Under a git hook (the pre-push `mix test`) git exports GIT_DIR
  # pointing at meerkat's own gitdir, which overrides `cd: dir` and
  # would build the fixture repo in the wrong place. Same set as
  # `Meerkat.Git` strips.
  @git_discovery_overrides Enum.map(
                             ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
                                GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
                                GIT_NAMESPACE),
                             &{&1, nil}
                           )

  @doc """
  Like `make_tmp_repo/1`, but the `.git` is a real `git init` so
  `Meerkat.Git` calls that shell out to git succeed.
  """
  @spec make_git_repo(String.t()) :: String.t()
  def make_git_repo(prefix \\ "meerkat-test") do
    dir = make_tmp_repo(prefix)
    File.rm_rf!(Path.join(dir, ".git"))

    {_, 0} =
      System.cmd("git", ["init", "-q"],
        cd: dir,
        stderr_to_stdout: true,
        env: @git_discovery_overrides
      )

    dir
  end
end
