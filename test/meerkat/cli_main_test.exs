defmodule Meerkat.CLIMainTest do
  # `Meerkat.CLI.main/1` end to end, for the invocations that decide
  # before a review server would start. Not async: these set MEERKAT_PWD
  # and PATH, which are process-global.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers

  alias Meerkat.{CLI, PendingAnswers, PendingQuestions}

  setup do
    isolate_git_config()
    restore_signal_handler_on_exit()
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

  test "unanswered questions refuse every review target before resolving it or opening a page",
       %{repo: repo, commit_msg: commit_msg} do
    question = %{location: "src/x.rs:2 (old)", question: "Why remove this?"}
    :ok = PendingQuestions.replace(repo, [question])
    env_before = Application.get_all_env(:meerkat)

    for argv <- [[], ["--commit-msg", commit_msg], ["HEAD"], ["A..B"], ["A...B"], ["--pr", "123"]] do
      {code, stderr} = run_main(argv ++ ["--no-open"])
      assert code == 1
      assert stderr =~ "review refused because these questions are unanswered"
      assert stderr =~ "src/x.rs:2 (old)"
      assert stderr =~ "Why remove this?"
      assert stderr =~ "meerkat --answers <<'JSON'"
      assert stderr =~ "re-run the command that was refused"
      refute stderr =~ "auto-approving"
      refute stderr =~ "Paused for human review"
      assert Application.get_all_env(:meerkat) == env_before
    end
  end

  test "partial answers list only the remaining question; a complete set passes the question gate",
       %{repo: repo} do
    answered = %{location: "global", question: "Answered question?"}
    missing = %{location: "file: src/x.rs", question: "Still missing?"}
    :ok = PendingQuestions.replace(repo, [answered, missing])
    {:ok, 1} = PendingAnswers.save(repo, answer_json([answered]))

    {1, stderr} = run_main(["--no-open"])
    assert stderr =~ "file: src/x.rs"
    assert stderr =~ "Still missing?"
    refute stderr =~ "Answered question?"

    # This ref cannot resolve. Reaching its 64 proves the gate has let the
    # complete set through without starting an endpoint or waiting on a user.
    stub_gh(repo, "exit 1")
    {:ok, 2} = PendingAnswers.save(repo, answer_json([answered, missing]))
    {64, stderr} = run_main(["no-such-ref", "--no-open"])
    assert stderr =~ "error resolving review target"
    refute stderr =~ "review refused"
    assert length(PendingAnswers.load(repo).answers) == 2
    assert CLI.auto_approve_decision_for_test(repo) == :live
  end

  test "a served restart and a missing temporary index cannot bypass the question gate", %{
    repo: repo
  } do
    :ok = PendingQuestions.replace(repo, [%{location: "global", question: "Still owed?"}])
    serve_dir = Path.join(repo, "run")
    File.mkdir_p!(serve_dir)
    File.write!(Path.join(serve_dir, "served"), "")
    put_env("MEERKAT_SERVE_DIR", serve_dir)
    put_env("GIT_INDEX_FILE", Path.join(repo, "missing-index"))
    {1, stderr} = run_main(["--no-open"])
    assert stderr =~ "Still owed?"
    refute stderr =~ "index"
  end

  test "corrupt obligations reject instead of opening or auto-approving", %{repo: repo} do
    :ok = PendingQuestions.replace(repo, [])
    path = PendingQuestions.path_for(repo)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "broken JSON")
    {:error, reason} = PendingQuestions.unanswered(repo)
    {2, stderr} = run_main(["--no-open"])

    assert stderr ==
             "meerkat: couldn't read owed questions: #{reason} — defaulting to REJECT (commit aborted).\n"

    refute stderr =~ "auto-approving"
    assert File.read!(path) == "broken JSON"
  end

  defp answer_json(questions),
    do: Jason.encode!(%{answers: Enum.map(questions, &Map.put(&1, :answer, "Because."))})

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

  describe "under a launcher, for a commit made from a temporary index" do
    # Stage only a linguist-generated file so auto-approval reveals which index
    # the review read. An empty index would also auto-approve, but as having
    # nothing staged.
    setup %{repo: repo} do
      File.write!(Path.join(repo, ".gitattributes"), "gen.txt linguist-generated\n")
      index = temporary_index(repo, "index.lock", %{"gen.txt" => "generated\n"})
      serve_dir = Path.join(repo, ".git/run")
      File.mkdir_p!(serve_dir)
      put_env("MEERKAT_SERVE_DIR", serve_dir)
      put_env("GIT_INDEX_FILE", index)
      on_exit(fn -> Application.delete_env(:meerkat, :held_index) end)

      {:ok, index: index, serve_dir: serve_dir}
    end

    test "the review keeps a copy of the index, and reads it once git has deleted it",
         %{commit_msg: commit_msg, index: index, serve_dir: serve_dir} do
      {code, stderr} = run_main(["--commit-msg", commit_msg, "--no-open"])
      assert code == 0
      assert stderr =~ "staged file(s) are linguist-generated — auto-approving."
      assert File.exists?(Path.join(serve_dir, "index"))

      File.rm!(index)
      Application.delete_env(:meerkat, :held_index)

      {code, stderr} = run_main(["--commit-msg", commit_msg, "--no-open"])
      assert code == 0
      assert stderr =~ "staged file(s) are linguist-generated — auto-approving."
    end

    test "an index git removed before the review could copy it rejects the commit",
         %{commit_msg: commit_msg, index: index} do
      File.rm!(index)

      {code, stderr} = run_main(["--commit-msg", commit_msg, "--no-open"])
      assert code == 2

      assert stderr =~
               ~r/^meerkat: the commit's index .+ no longer exists — defaulting to REJECT \(commit aborted\)\.$/m
    end
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

  # OTP's own SIGTERM handling would exit 0 here, which means approved.
  test "a SIGTERM while the review target resolves exits 143 with a REJECT message",
       %{repo: repo} do
    stub_gh(repo, ~s(kill -TERM "$MEERKAT_TEST_BEAM"; sleep 10))

    {output, code} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "--no-compile",
          "-e",
          ~s|System.put_env("MEERKAT_TEST_BEAM", System.pid()); | <>
            "System.halt(Meerkat.CLI.main(System.argv()))",
          "--",
          "HEAD",
          "--no-open"
        ],
        env: [{"MIX_ENV", to_string(Mix.env())}],
        stderr_to_stdout: true
      )

    assert code == 143
    assert output =~ "meerkat: received SIGTERM"
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
end
