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

  # Any test run inside a git hook has GIT_DIR exported by git, pointing at
  # meerkat's own gitdir, which overrides `cd: dir` and would build the
  # fixture repo in the wrong place. The set `Meerkat.Git` strips, plus
  # GIT_INDEX_FILE, which it leaves for the staged reads of a review.
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
  Build an index like the temporary index Git gives the hook for
  `git commit -a` or `git commit <path>`.

  The index is created at `.git/<name>` under `dir`, initialized from
  `HEAD`, and has each `files` entry staged; each file is also written to
  the work tree. The repository's own index is left untouched. Returns
  the path to the temporary index.
  """
  @spec temporary_index(String.t(), String.t(), %{String.t() => String.t()}) :: String.t()
  def temporary_index(dir, name, files) do
    index = Path.join(dir, ".git/" <> name)

    env = [
      {"GIT_INDEX_FILE", index} | List.keydelete(@git_discovery_overrides, "GIT_INDEX_FILE", 0)
    ]

    in_index = fn args ->
      {out, code} = System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: env)
      if code != 0, do: ExUnit.Assertions.flunk("git #{Enum.join(args, " ")} failed: #{out}")
    end

    in_index.(["read-tree", "HEAD"])

    for {file, content} <- files do
      path = Path.join(dir, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      in_index.(["add", "--", file])
    end

    index
  end

  @doc """
  Installs this repo's lefthook into the fixture repo `work`, which must
  already hold a copy of lefthook.yml.
  """
  @spec install_lefthook(String.t()) :: :ok
  def install_lefthook(work) do
    # Where `pnpm install` puts it, for lefthook.yml's `lefthook:` setting.
    File.mkdir_p!(Path.join(work, "node_modules/.bin"))
    File.ln_s!(lefthook_bin(), Path.join(work, "node_modules/.bin/lefthook"))

    {_, 0} =
      System.cmd(lefthook_bin(), ["install"], cd: work, env: hook_env(), stderr_to_stdout: true)

    :ok
  end

  defp lefthook_bin do
    root = Path.expand("../..", __DIR__)

    case Path.wildcard(
           Path.join(root, "node_modules/.pnpm/lefthook-*/node_modules/lefthook-*/bin/lefthook")
         ) do
      [bin | _] ->
        bin

      [] ->
        ExUnit.Assertions.flunk(
          "lefthook binary not found under node_modules; run `pnpm install`"
        )
    end
  end

  @doc """
  Environment for running git commands that fire the fixture's hooks.

  Git exports GIT_DIR and friends to hooks; clearing them lets a run from
  inside a hook still act on the fixture. LEFTHOOK=0 would silently disable
  the hook, and LEFTHOOK_BIN would bypass lefthook.yml's `lefthook:` setting.
  """
  @spec hook_env() :: [{String.t(), nil}]
  def hook_env, do: [{"LEFTHOOK_BIN", nil}, {"LEFTHOOK", nil} | @git_discovery_overrides]

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

  @doc """
  Builds a temporary Git repo named with `prefix` via `make_git_repo/1` and
  removes it when the test exits. On branch `feature`, it creates a commit
  changing `one.rs` to `fn one() -> i32 { 1 }\\n` and `two.rs` to
  `fn two() -> i32 { 2 }\\n`; both contents are recorded as approved in
  Meerkat's approval cache for `feature`.

  It starts an interactive rebase, stops at an `edit` of that commit, then
  runs `git reset HEAD~`. The returned repo is detached mid-rebase, with both
  changes unstaged in the worktree—the state used when splitting a commit.

  Returns the repo directory.
  """
  @spec split_approved_commit_mid_rebase(String.t()) :: String.t()
  def split_approved_commit_mid_rebase(prefix) do
    dir = make_git_repo(prefix)
    on_exit(fn -> File.rm_rf!(dir) end)
    git(dir, ["config", "user.email", "t@t.t"])
    git(dir, ["config", "user.name", "t"])
    stage(dir, "one.rs", "fn one() {}\n")
    stage(dir, "two.rs", "fn two() {}\n")
    git(dir, ["commit", "-qm", "seed"])
    git(dir, ["switch", "-qc", "feature"])
    stage(dir, "one.rs", "fn one() -> i32 { 1 }\n")
    stage(dir, "two.rs", "fn two() -> i32 { 2 }\n")

    {:ok, _} =
      Meerkat.ApprovalCache.modify(Meerkat.ApprovalCache.path_for(dir), fn cache ->
        Enum.reduce(["one.rs", "two.rs"], cache, fn name, acc ->
          Meerkat.ApprovalCache.approve(
            acc,
            "feature",
            name,
            git(dir, ["rev-parse", ":" <> name])
          )
        end)
      end)

    git(dir, ["commit", "-qm", "both"])

    git(dir, ["-c", "sequence.editor=sed -i.bak -e 1s/^pick/edit/", "rebase", "-q", "-i", "HEAD~"])

    git(dir, ["reset", "-q", "HEAD~"])
    dir
  end
end
