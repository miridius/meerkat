defmodule Meerkat.CLIMainTest do
  # `Meerkat.CLI.main/1` end to end, for the invocations that decide
  # before a review server would start. Not async: these set MEERKAT_PWD
  # and PATH, which are process-global.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers

  alias Meerkat.CLI

  setup do
    isolate_git_config()
    repo = make_git_repo("meerkat-cli-main")
    git(repo, ["config", "user.email", "t@t.t"])
    git(repo, ["config", "user.name", "t"])
    git(repo, ["commit", "--allow-empty", "-qm", "initial"])
    commit_msg = Path.join(repo, "COMMIT_MSG")
    File.write!(commit_msg, "Subject\n")

    put_env("MEERKAT_PWD", repo)
    put_env("MEERKAT_SERVE_DIR", nil)
    on_exit(fn -> File.rm_rf!(repo) end)

    {:ok, repo: repo, commit_msg: commit_msg}
  end

  test "a commit with no staged file changes auto-approves without opening a review",
       %{commit_msg: commit_msg} do
    env_before = Application.get_all_env(:meerkat)

    {code, stderr} = run_main(["--commit-msg", commit_msg, "--no-open"])

    assert code == 0
    assert stderr =~ "meerkat: no staged file changes — auto-approving."
    refute stderr =~ "Paused for human review"
    # Starting a review puts its target and endpoint config in the app env.
    assert Application.get_all_env(:meerkat) == env_before
  end

  # Without a UTF-8 locale the BEAM opens stderr as latin1 and writes
  # each non-latin1 character as an escape like `\x{2014}`.
  test "stderr is UTF-8 when no locale is set", %{repo: repo, commit_msg: commit_msg} do
    {stderr, 0} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "--no-compile",
          "-e",
          "System.halt(Meerkat.CLI.main(System.argv()))"
        ] ++
          ["--", "--commit-msg", commit_msg, "--no-open"],
        env: [
          {"LANG", nil},
          {"LC_ALL", nil},
          {"LC_CTYPE", nil},
          {"MEERKAT_PWD", repo},
          {"MIX_ENV", to_string(Mix.env())}
        ],
        stderr_to_stdout: true
      )

    assert stderr =~ "meerkat: no staged file changes — auto-approving."
  end

  test "a ref that does not resolve exits 64 and says the target could not be resolved",
       %{repo: repo} do
    # `gh` answers the current-branch PR lookup the way it does for a
    # branch with no PR, so the test never reaches GitHub.
    stub_gh(repo, ~s(echo 'no pull requests found for branch "main"' >&2; exit 1))
    env_before = Application.get_all_env(:meerkat)

    {code, stderr} = run_main(["no-such-ref", "--no-open"])

    assert code == 64
    # A whole line: a crash's stack trace can quote the same text.
    assert stderr =~ ~r/^meerkat: error resolving review target: /m
    assert Application.get_all_env(:meerkat) == env_before
  end

  # A regression that opens a review would block on a human forever.
  defp run_main(argv) do
    task =
      Task.async(fn ->
        ExUnit.CaptureIO.with_io(:stderr, fn -> CLI.main(argv) end)
      end)

    case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> flunk("CLI.main(#{inspect(argv)}) did not return within 10 s")
    end
  end

  defp stub_gh(dir, body) do
    bin = Path.join(dir, "gh-stub")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "gh"), "#!/bin/sh\n#{body}\n")
    File.chmod!(Path.join(bin, "gh"), 0o755)
    put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
  end

  defp put_env(name, value) do
    previous = System.get_env(name)
    if value, do: System.put_env(name, value), else: System.delete_env(name)

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end
end
