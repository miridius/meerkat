defmodule Meerkat.AutoInstallScriptTest do
  # Runs the repo's real scripts/auto-install.sh in a throwaway repo, with
  # the environment git gives a post-checkout hook. scripts/install.sh and
  # `mix` are stubs that log each run and the git variables it sees.
  use ExUnit.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2]

  @root File.cwd!()

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-auto-install")
    on_exit(fn -> File.rm_rf!(base) end)
    File.rm_rf!(Path.join(base, ".git"))

    repo = Path.join(base, "repo")
    shim = Path.join(base, "shim")
    log = Path.join(base, "log")

    File.mkdir_p!(Path.join(repo, "scripts"))

    File.cp!(
      Path.join(@root, "scripts/auto-install.sh"),
      Path.join(repo, "scripts/auto-install.sh")
    )

    File.write!(Path.join(repo, "scripts/install.sh"), "echo install.sh >> '#{log}'\n")
    git(base, ["init", "-q", "--initial-branch=main", repo])
    git(repo, ["add", "."])
    git(repo, ["-c", "user.email=t@t.t", "-c", "user.name=t", "commit", "-q", "-m", "base"])

    File.mkdir_p!(shim)

    File.write!(Path.join(shim, "mix"), """
    #!/usr/bin/env bash
    echo "MIX_ENV=${MIX_ENV:-} mix $*" >> '#{log}'
    env | grep -E '^GIT_(DIR|INDEX_FILE|WORK_TREE)=' | sed 's/^/  leaked /' >> '#{log}'
    exit 0
    """)

    File.chmod!(Path.join(shim, "mix"), 0o755)

    # What git exports to a hook it runs in this checkout.
    env = [
      {"PATH", shim <> ":" <> System.get_env("PATH")},
      {"GIT_DIR", Path.join(repo, ".git")},
      {"GIT_INDEX_FILE", Path.join(repo, ".git/index")}
    ]

    {:ok, repo: repo, log: log, env: env}
  end

  test "on main, installs and then refreshes the test env's deps and build", ctx do
    assert {_, 0} = auto_install(ctx)

    assert log(ctx) == [
             "install.sh",
             "MIX_ENV=test mix deps.get",
             "MIX_ENV=test mix compile"
           ]
  end

  test "off main, does nothing", ctx do
    git(ctx.repo, ["switch", "-q", "-c", "feature"])

    assert {_, 0} = auto_install(ctx)
    assert log(ctx) == []
  end

  defp auto_install(ctx) do
    System.cmd("bash", ["scripts/auto-install.sh"],
      cd: ctx.repo,
      env: ctx.env,
      stderr_to_stdout: true
    )
  end

  defp log(ctx) do
    case File.read(ctx.log) do
      {:ok, log} -> String.split(log, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end
end
