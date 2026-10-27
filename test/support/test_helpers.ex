defmodule Meerkat.TestHelpers do
  @moduledoc """
  Shared test helpers. Importable from ExUnit cases without dragging
  in the `ConnCase` setup.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  # Git reads only test.gitconfig, never the caller's or the system's
  # config. The caller's identity variables would override the fixture's
  # user.email.
  @git_config_env %{
    "GIT_CONFIG_GLOBAL" => Path.expand("test.gitconfig", __DIR__),
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_CONFIG_COUNT" => "0",
    "GIT_CONFIG_PARAMETERS" => nil,
    "GIT_AUTHOR_NAME" => nil,
    "GIT_AUTHOR_EMAIL" => nil,
    "GIT_COMMITTER_NAME" => nil,
    "GIT_COMMITTER_EMAIL" => nil,
    "EMAIL" => nil
  }

  @doc """
  Sets the git config environment for the whole test BEAM, so every git a
  test starts inherits it. test_helper.exs calls it once; a synchronous
  test that changes it with `put_env/2` can call it again to return to it
  mid-test.
  """
  def put_git_config_env, do: Enum.each(@git_config_env, &put_env/1)

  # `Meerkat.CLI.main/1` installs `Meerkat.SignalHandler` VM-wide; put
  # OTP's handler back so a SIGTERM to the test VM stops it as usual.
  def restore_signal_handler_on_exit do
    on_exit(fn ->
      if Meerkat.SignalHandler in :gen_event.which_handlers(:erl_signal_server) do
        :ok =
          :gen_event.swap_handler(
            :erl_signal_server,
            {Meerkat.SignalHandler, []},
            {:erl_signal_handler, []}
          )
      end
    end)
  end

  @doc """
  Calls `fun` every `:interval` ms (10) until it returns a truthy value,
  and returns that value, or `nil` once `:timeout` ms have passed, by
  default when an `assert_receive` would have given up. Waits for what a
  test needs to happen rather than a fixed time, which a loaded machine
  can overrun; the caller asserts on the result. A `fun` that starts a
  process takes a longer interval, so the wait adds less load.
  """
  @spec eventually((-> result), timeout: non_neg_integer(), interval: pos_integer()) ::
          result | nil
        when result: term()
  def eventually(fun, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        timeout: ExUnit.configuration()[:assert_receive_timeout],
        interval: 10
      )

    poll_until(fun, System.monotonic_time(:millisecond) + opts[:timeout], opts[:interval])
  end

  defp poll_until(fun, deadline, interval_ms) do
    cond do
      result = fun.() ->
        result

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        Process.sleep(interval_ms)
        poll_until(fun, deadline, interval_ms)
    end
  end

  @owned_tmp_dir_re ~r/^(\d+)-\d+$/

  @doc """
  Points TMPDIR, and so `System.tmp_dir!/0` and every child process, at a
  new `meerkat-exunit/<OS pid>-<n>` dir under the system temp dir, removed
  after the suite. Called once from `test_helper.exs`.

  First runs `reap_orphaned_tmp_dirs/1`, so the dirs of BEAMs killed before
  their suite finished go with the next run. It lists only `meerkat-exunit`,
  as the system temp dir can hold far more entries than is quick to list.
  """
  @spec isolate_tmp_dir() :: :ok
  def isolate_tmp_dir do
    parent = Path.join(System.tmp_dir!(), "meerkat-exunit")
    File.mkdir_p!(parent)
    reap_orphaned_tmp_dirs(parent)
    dir = Path.join(parent, "#{System.pid()}-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(dir)
    System.put_env("TMPDIR", dir)
    ExUnit.after_suite(fn _ -> File.rm_rf(dir) end)
  end

  @doc """
  Removes each `isolate_tmp_dir/0` dir in `parent` whose BEAM is no longer
  alive. Those of live BEAMs, including concurrent runs, are left alone.
  """
  @spec reap_orphaned_tmp_dirs(String.t()) :: :ok
  def reap_orphaned_tmp_dirs(parent) do
    for name <- File.ls!(parent),
        [_, pid] <- [Regex.run(@owned_tmp_dir_re, name)],
        not os_pid_alive?(pid) do
      # Not rm_rf!: BEAMs starting together reap the same dirs at once.
      File.rm_rf(Path.join(parent, name))
    end

    :ok
  end

  defp os_pid_alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

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

  @doc """
  Set environment variable `name` to `value`, or unset it when `value` is
  `nil`, for the rest of the current test; restored on exit.
  """
  def put_env(name, value) do
    previous = System.get_env(name)
    put_env({name, value})
    on_exit(fn -> put_env({name, previous}) end)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  @doc """
  A path `<tmpdir>/<prefix>-<unique>-<os_time>-<rand>` that no other test
  run uses, without creating it.

  `unique_integer/1` is unique only *within* a BEAM. Each test BEAM has its
  own TMPDIR, but the `os_time` and random parts keep the path unique when
  something points TMPDIR at a dir other BEAMs share.
  """
  @spec tmp_path(String.t()) :: String.t()
  def tmp_path(prefix) do
    suffix =
      [
        System.unique_integer([:positive]),
        System.os_time(:nanosecond),
        :rand.uniform(1_000_000)
      ]
      |> Enum.join("-")

    Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")
  end

  @doc """
  Build a unique `tmp_path/1` directory with a `.git` subdir so
  `Meerkat.Git.git_dir/1` resolves under the ceiling.
  """
  @spec make_tmp_repo(String.t()) :: String.t()
  def make_tmp_repo(prefix \\ "meerkat-test") do
    dir = tmp_path(prefix)
    File.mkdir_p!(Path.join(dir, ".git"))
    dir
  end

  @doc """
  Copies the fixture tree `template` to a new `tmp_path/1` dir named with
  `prefix`, removed when the test exits, and returns the copy. Each file
  outside git's object stores that names `template`, such as a remote's
  URL in a git config, a hook or a stub script, names the copy instead.
  Commits keep naming `template`, so a fixture whose tracked files name it
  cannot be copied this way.

  A module that builds the same fixture for every test builds it once in
  `setup_all` and copies it per test: under load, each git or lefthook
  process that builds it costs a test seconds.
  """
  @spec copy_fixture(String.t(), String.t()) :: String.t()
  def copy_fixture(template, prefix) do
    dir = tmp_path(prefix)
    File.cp_r!(template, dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
        "objects" not in Path.split(Path.relative_to(path, dir)),
        File.lstat!(path).type == :regular,
        content = File.read!(path),
        String.contains?(content, template) do
      File.write!(path, String.replace(content, template, dir))
    end

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

  @doc """
  Runs a bash `gate` in the git repo `repo`: it takes a slot with this
  repo's scripts/gate-lock.sh, then runs the bash `command`. The port
  delivers its output, stderr included, line by line, and its exit status.
  Closing the port closes the gate's stdin. A gate that gets no slot gives
  up after `:timeout` seconds (default 60). `:bash` is the bash that runs
  it (default the one on PATH).
  """
  @spec gate_lock_port(String.t(), String.t(), keyword()) :: port()
  def gate_lock_port(repo, command, opts \\ []) do
    lib = Path.expand("../../scripts/gate-lock.sh", __DIR__)

    env = [
      {~c"MEERKAT_GATE_LOCK_TIMEOUT", ~c"#{Keyword.get(opts, :timeout, 60)}"}
      | for({name, nil} <- @git_discovery_overrides, do: {String.to_charlist(name), false})
    ]

    bash = Keyword.get_lazy(opts, :bash, fn -> System.find_executable("bash") end)

    Port.open({:spawn_executable, bash}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 4096},
      args: ["-c", ~s(set -e; source "$0"; gate_lock; #{command}), lib],
      cd: repo,
      env: env
    ])
  end

  @doc """
  Takes a gate slot in the git repo `repo` and returns once it holds it.
  The slot stays taken until the returned port is closed.
  """
  @spec hold_gate_slot(String.t()) :: port()
  def hold_gate_slot(repo) do
    port = gate_lock_port(repo, "echo held; read -r _")

    receive do
      {^port, {:data, {:eol, "held"}}} -> port
    after
      ExUnit.configuration()[:assert_receive_timeout] ->
        ExUnit.Assertions.flunk("no gate slot came free in #{repo}")
    end
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
  A gate that gets no slot gives up after a minute rather than the default
  hour, so a test that leaves slots taken fails instead of hanging.
  """
  @spec hook_env() :: [{String.t(), String.t() | nil}]
  def hook_env do
    [
      {"LEFTHOOK_BIN", nil},
      {"LEFTHOOK", nil},
      {"MEERKAT_GATE_LOCK_TIMEOUT", "60"}
      | @git_discovery_overrides
    ]
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

  @doc """
  Commit what is staged in `repo`, or nothing, as a throwaway author.
  """
  @spec commit(String.t(), String.t()) :: String.t()
  def commit(repo, message) do
    git(repo, [
      "-c",
      "user.email=t@t",
      "-c",
      "user.name=t",
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      message
    ])
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
