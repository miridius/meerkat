defmodule Meerkat.TestHelpers do
  @moduledoc """
  Shared test helpers. Importable from ExUnit cases without dragging
  in the `ConnCase` setup.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  # These helpers change process-wide environment and are only safe in
  # synchronous test cases. Restore it even when the test fails.
  def isolate_git_config do
    overrides = %{
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_COUNT" => "0",
      "GIT_CONFIG_PARAMETERS" => nil
    }

    previous = Map.new(overrides, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(overrides, &put_env/1)
    on_exit(fn -> Enum.each(previous, &put_env/1) end)
  end

  def stage(dir, name, content) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    git(dir, ["add", "--", name])
  end

  # Fault injection only at the process boundary; successful reads still
  # use real commits, blobs and diffs. Actions can invoke "$real_git".
  def intercept_git(dir, arg, action) do
    real_git = System.find_executable("git")
    old_path = System.fetch_env!("PATH")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "git"), """
    #!/bin/sh
    real_git=#{shell_quote(real_git)}
    for arg in "$@"; do
      if [ "$arg" = #{shell_quote(arg)} ]; then
        #{action}
      fi
    done
    exec "$real_git" "$@"
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)
    System.put_env("PATH", bin <> ":" <> old_path)
    on_exit(fn -> System.put_env("PATH", old_path) end)
  end

  defp put_env({key, nil}), do: System.delete_env(key)
  defp put_env({key, value}), do: System.put_env(key, value)

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

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

  @spec git(String.t(), [String.t()]) :: String.t()
  def git(dir, args) do
    {out, code} =
      System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: @git_discovery_overrides)

    if code != 0, do: ExUnit.Assertions.flunk("git #{Enum.join(args, " ")} failed: #{out}")
    String.trim(out)
  end

  @doc """
  Like `make_tmp_repo/1`, but the `.git` is a real `git init` so
  `Meerkat.Git` calls that shell out to git succeed.
  """
  @spec make_git_repo(String.t()) :: String.t()
  def make_git_repo(prefix \\ "meerkat-test") do
    dir = make_tmp_repo(prefix)
    File.rm_rf!(Path.join(dir, ".git"))

    git(dir, ["init", "-q"])

    dir
  end
end
