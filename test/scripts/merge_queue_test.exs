defmodule Meerkat.MergeQueueTest do
  # Runs scripts/merge-queue.sh against a stub `gh` on PATH. The stub answers
  # each `gh pr view` with the next JSON line from that PR's fixture (the last
  # line repeats) and applies the script's own `-q`/`--jq` filters with jq, so
  # those filters are exercised against gh-shaped JSON. A PR behind main is
  # rebased with real git, in a fixture clone of a fixture origin.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, stage: 3, hook_env: 0]

  @script Path.expand("scripts/merge-queue.sh")

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-merge-queue")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(Path.join(dir, "bin"))
    gh = Path.join([dir, "bin", "gh"])

    # `@pushed@` in a fixture line stands for the head the queue pushed.
    File.write!(gh, ~S"""
    #!/usr/bin/env bash
    dir=$(dirname "$0")/..
    echo "$*" >> "$dir/log"
    case "$1 $2" in
      "pr view")
        f="$dir/view-$3"
        [ -f "$f" ] || { echo "GraphQL: Could not resolve to a PullRequest with the number of $3." >&2; exit 1; }
        pushed=$(git --git-dir="$dir/origin.git" rev-parse --verify --quiet refs/heads/claude/feature 2>/dev/null)
        head -n 1 "$f" | sed "s/@pushed@/$pushed/g" > "$dir/line"
        if [ "$(wc -l < "$f")" -gt 1 ]; then tail -n +2 "$f" > "$f.next"; mv "$f.next" "$f"; fi
        q=""; prev=""
        for a in "$@"; do [ "$prev" = -q ] && q=$a; prev=$a; done
        if [ -n "$q" ]; then jq -r "$q" < "$dir/line"; else cat "$dir/line"; fi
        ;;
      "pr checks")
        case " $* " in
          *" --watch "*)
            cat "$dir/watch-out-$3" 2>/dev/null
            exit "$(cat "$dir/checks-status-$3" 2>/dev/null || echo 0)"
            ;;
        esac
        cat "$dir/checks-table-$3" 2>/dev/null ||
          printf 'test\tfail\t4m2s\thttps://github.com/o/r/actions/runs/1/job/2\n'
        exit 1
        ;;
      "api -X")
        case "$4" in
          */merge-async)
            n=${4%/merge-async}; n=${n##*/}
            cat "$dir/merge-out-$n" 2>/dev/null || echo "{\"status\":\"merged\",\"details\":{\"sha\":\"sq$n\"}}"
            exit "$(cat "$dir/merge-status-$n" 2>/dev/null || echo 0)"
            ;;
        esac
        exit "$(cat "$dir/delete-status" 2>/dev/null || echo 0)"
        ;;
      "api "*)
        jq=""; prev=""
        for a in "$@"; do [ "$prev" = --jq ] && jq=$a; prev=$a; done
        case "$2" in
          */merge-async/*)
            f="$dir/merge-poll"
            head -n 1 "$f"
            if [ "$(wc -l < "$f")" -gt 1 ]; then tail -n +2 "$f" > "$f.next"; mv "$f.next" "$f"; fi
            ;;
          *"pulls?"*) jq -r "$jq" < "$dir/pulls.json" 2>/dev/null || jq -r "$jq" <<< '[]' ;;
          */pulls/*) n=${2##*/}; { cat "$dir/pull-$n.json" 2>/dev/null || echo '{}'; } | jq -r "$jq" ;;
        esac
        ;;
    esac
    """)

    File.chmod!(gh, 0o755)

    # The worktree setup before a push, logged with where it ran.
    for tool <- ~w(mix pnpm) do
      stub = Path.join([dir, "bin", tool])

      File.write!(stub, """
      #!/usr/bin/env bash
      echo "#{tool} $* in $(git rev-parse HEAD)" >> '#{dir}/log'
      exit "$(cat '#{dir}/setup-status' 2>/dev/null || echo 0)"
      """)

      File.chmod!(stub, 0o755)
    end

    {:ok, dir: dir}
  end

  defp pr(dir, number, states) do
    lines = Enum.map(states, &(&1 |> view() |> JSON.encode!()))
    File.write!(Path.join(dir, "view-#{number}"), Enum.join(lines, "\n") <> "\n")
  end

  # `checks` is whether the head has any checks registered yet; their results
  # come from `gh pr checks --watch`, stubbed per PR with a checks-status file.
  defp view({head, merge_state, checks}), do: view({head, merge_state, checks, "OPEN"})

  defp view({head, merge_state, checks, state}),
    do: view({head, merge_state, checks, state, "claude/#{head}"})

  defp view({head, merge_state, checks, state, branch}) do
    checks = if checks, do: [%{name: "test", status: "IN_PROGRESS", conclusion: ""}], else: []

    %{
      state: state,
      headRefOid: head,
      headRefName: branch,
      baseRefName: "main",
      mergeStateStatus: merge_state,
      mergeable: if(merge_state == "DIRTY", do: "CONFLICTING", else: "MERGEABLE"),
      url: "https://github.com/o/r/pull/1",
      statusCheckRollup: checks
    }
  end

  # An origin whose branch claude/feature is one commit behind main, and a
  # clone of it the queue runs in. The clone's pre-push hook stands in for
  # the gates: it logs the commit it was asked to push and fails when told
  # to. With `conflict: true`, main and the branch change the same line.
  # Returns the clone and the branch's head.
  defp behind_branch(dir, opts \\ []) do
    origin = Path.join(dir, "origin.git")
    work = Path.join(dir, "work")
    git(dir, ["init", "-q", "--bare", "--initial-branch=main", origin])
    git(dir, ["init", "-q", "--initial-branch=main", work])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])
    git(work, ["remote", "add", "origin", origin])
    commit(work, "code.txt", "base\n")
    git(work, ["push", "-q", "origin", "main"])
    git(work, ["switch", "-q", "-c", "claude/feature"])
    commit(work, "code.txt", "feature\n")
    git(work, ["push", "-q", "origin", "claude/feature"])
    feature = git(work, ["rev-parse", "HEAD"])
    git(work, ["switch", "-q", "main"])

    if opts[:conflict],
      do: commit(work, "code.txt", "main\n"),
      else: commit(work, "main.txt", "main\n")

    git(work, ["push", "-q", "origin", "main"])

    hook = Path.join([work, ".git", "hooks", "pre-push"])

    File.write!(hook, """
    #!/usr/bin/env bash
    echo "pre-push $(git rev-parse HEAD)" >> '#{dir}/log'
    echo "the gates' last words"
    exit "$(cat '#{dir}/push-status' 2>/dev/null || echo 0)"
    """)

    File.chmod!(hook, 0o755)
    {work, feature}
  end

  defp commit(work, name, content) do
    stage(work, name, content)
    git(work, ["commit", "-qm", name])
  end

  defp origin_head(dir, ref), do: git(Path.join(dir, "origin.git"), ["rev-parse", ref])

  defp worktrees(work) do
    git(work, ["worktree", "list", "--porcelain"])
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "worktree "))
  end

  defp run_queue(dir, prs, env \\ [], cd \\ nil) do
    env = [
      {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
      {"MERGE_QUEUE_POLL", "0"} | env ++ hook_env()
    ]

    System.cmd("bash", [@script | prs], env: env, stderr_to_stdout: true, cd: cd || File.cwd!())
  end

  defp log(dir), do: dir |> Path.join("log") |> File.read!() |> String.split("\n", trim: true)

  defp calls(dir, prefix), do: Enum.filter(log(dir), &String.starts_with?(&1, prefix))

  defp merges(dir), do: calls(dir, "api -X PUT")

  defp merge(n, sha),
    do:
      "api -X PUT repos/{owner}/{repo}/pulls/#{n}/merge-async -f sha=#{sha} " <>
        "-f merge_method=squash -f merge_action=direct_merge"

  test "an up-to-date PR whose checks pass is squash-merged at its head", %{dir: dir} do
    pr(dir, 1, [{"aaa", "CLEAN", true}])

    assert run_queue(dir, ["1"]) == {"#1 merged sq1\n", 0}
    assert calls(dir, "pr checks") == ["pr checks 1 --watch --fail-fast --interval 0"]
    assert merges(dir) == [merge(1, "aaa")]

    assert calls(dir, "api -X DELETE") == [
             "api -X DELETE repos/{owner}/{repo}/git/refs/heads/claude/aaa"
           ]
  end

  test "a merge GitHub is still processing is followed to its result", %{dir: dir} do
    pr(dir, 1, [{"aaa", "CLEAN", true}])

    File.write!(
      Path.join(dir, "merge-out-1"),
      ~s({"status":"pending","details":{"uuid":"u1"}}\n)
    )

    File.write!(Path.join(dir, "merge-poll"), """
    {"status":"pending","details":{"uuid":"u1"}}
    {"status":"merged","details":{"sha":"abc123"}}
    """)

    assert run_queue(dir, ["1"]) == {"#1 merged abc123\n", 0}
    assert calls(dir, "api repos/{owner}/{repo}/pulls/1/merge-async/u1") |> length() == 2
  end

  test "a PR above open PRs in a GitHub stack is not merged", %{dir: dir} do
    pr(dir, 1, [{"aaa", "CLEAN", true}])
    File.write!(Path.join(dir, "pull-1.json"), ~s({"stack":{"id":9,"position":3}}))

    File.write!(
      Path.join(dir, "pulls.json"),
      JSON.encode!([
        %{number: 1, stack: %{id: 9, position: 3}},
        %{number: 2, stack: %{id: 9, position: 2}},
        %{number: 3, stack: %{id: 8, position: 1}},
        %{number: 4, stack: nil}
      ])
    )

    assert run_queue(dir, ["1"]) ==
             {"#1 has open PRs below it in its stack: #2\nnot attempted:\n", 1}

    assert merges(dir) == []
  end

  test "a PR whose stack has nothing open below it is merged", %{dir: dir} do
    pr(dir, 1, [{"aaa", "CLEAN", true}])
    File.write!(Path.join(dir, "pull-1.json"), ~s({"stack":{"id":9,"position":2}}))

    File.write!(
      Path.join(dir, "pulls.json"),
      JSON.encode!([%{number: 1, stack: %{id: 9, position: 2}}])
    )

    assert run_queue(dir, ["1"]) == {"#1 merged sq1\n", 0}
  end

  test "a PR behind main is rebased onto it locally, pushed through the pre-push hook, then merged at the rebased head after its checks",
       %{dir: dir} do
    {work, feature} = behind_branch(dir)
    pr(dir, 1, [{"aaa", "CLEAN", true}])

    pr(dir, 2, [
      {feature, "BEHIND", true, "OPEN", "claude/feature"},
      {feature, "BEHIND", true, "OPEN", "claude/feature"},
      {"@pushed@", "UNKNOWN", false, "OPEN", "claude/feature"},
      {"@pushed@", "BLOCKED", false, "OPEN", "claude/feature"},
      {"@pushed@", "BLOCKED", true, "OPEN", "claude/feature"}
    ])

    assert {"#1 merged sq1\n#2 merged sq2 (rebased onto main)\n", 0} =
             run_queue(dir, ["1", "2@#{feature}"], [], work)

    rebased = origin_head(dir, "claude/feature")
    assert origin_head(dir, "#{rebased}~1") == origin_head(dir, "main")
    assert git(Path.join(dir, "origin.git"), ["show", "#{rebased}:code.txt"]) == "feature"
    # The worktree is set up, as check.sh sets one up, before the push.
    assert Enum.filter(log(dir), &(&1 =~ ~r/^(mix|pnpm|pre-push) /)) == [
             "mix deps.get in #{rebased}",
             "pnpm install --frozen-lockfile --ignore-scripts --prefer-offline in #{rebased}",
             "pre-push #{rebased}"
           ]

    # Only once the new head has checks registered are they watched.
    assert calls(dir, "pr view 2") |> length() == 6
    assert calls(dir, "pr checks 2") == ["pr checks 2 --watch --fail-fast --interval 0"]

    assert merges(dir) == [merge(1, "aaa"), merge(2, rebased)]

    assert Enum.find_index(log(dir), &(&1 =~ "pulls/1/merge-async")) <
             Enum.find_index(log(dir), &(&1 =~ "pre-push"))

    assert length(worktrees(work)) == 1
  end

  test "a rebase that conflicts with main stops the queue and pushes nothing", %{dir: dir} do
    {work, feature} = behind_branch(dir, conflict: true)
    pr(dir, 1, [{feature, "BEHIND", true, "OPEN", "claude/feature"}])

    assert {"#1 conflicts with main\n" <> rest, 1} = run_queue(dir, ["1", "2"], [], work)
    assert rest =~ "CONFLICT"
    assert String.ends_with?(rest, "not attempted: 2\n")
    assert origin_head(dir, "claude/feature") == feature
    assert length(worktrees(work)) == 1
    assert merges(dir) == []
  end

  test "a rebase the pre-push gates refuse stops the queue with their output", %{dir: dir} do
    {work, feature} = behind_branch(dir)
    pr(dir, 1, [{feature, "BEHIND", true, "OPEN", "claude/feature"}])
    File.write!(Path.join(dir, "push-status"), "1")

    assert {"#1 rebase onto main could not be pushed\n" <> rest, 1} =
             run_queue(dir, ["1"], [], work)

    assert rest =~ "the gates' last words"
    assert origin_head(dir, "claude/feature") == feature
    assert length(worktrees(work)) == 1
    assert merges(dir) == []
  end

  test "a worktree that cannot be set up stops the queue before any push", %{dir: dir} do
    {work, feature} = behind_branch(dir)
    pr(dir, 1, [{feature, "BEHIND", true, "OPEN", "claude/feature"}])
    File.write!(Path.join(dir, "setup-status"), "1")

    assert {"#1 could not be set up to push\n" <> _, 1} = run_queue(dir, ["1"], [], work)
    assert calls(dir, "pre-push") == []
    assert origin_head(dir, "claude/feature") == feature
    assert length(worktrees(work)) == 1
  end

  test "a head other than the rebased one stops the queue unmerged", %{dir: dir} do
    {work, feature} = behind_branch(dir)

    pr(dir, 1, [
      {feature, "BEHIND", true, "OPEN", "claude/feature"},
      {"zzz", "CLEAN", true, "OPEN", "claude/feature"}
    ])

    assert {out, 1} = run_queue(dir, ["1"], [], work)

    assert out ==
             "#1 head moved from #{origin_head(dir, "claude/feature")} to zzz\nnot attempted:\n"

    assert merges(dir) == []
  end

  test "a branch that moved since it was read is not overwritten", %{dir: dir} do
    {work, feature} = behind_branch(dir)
    pr(dir, 1, [{feature, "BEHIND", true, "OPEN", "claude/feature"}])
    other = Path.join(dir, "other")
    git(dir, ["clone", "-q", "--branch", "claude/feature", Path.join(dir, "origin.git"), other])
    git(other, ["config", "user.email", "t@t.t"])
    git(other, ["config", "user.name", "t"])
    commit(other, "late.txt", "late\n")
    git(other, ["push", "-q", "origin", "claude/feature"])
    moved = git(other, ["rev-parse", "HEAD"])

    # The fetch brings the moved branch, but the lease is on the head read.
    assert {"#1 rebase onto main could not be pushed\n" <> _, 1} = run_queue(dir, ["1"], [], work)
    assert origin_head(dir, "claude/feature") == moved
  end

  test "a PR whose head moved past its reviewed SHA stops the queue unmerged", %{dir: dir} do
    pr(dir, 1, [{"zzz", "CLEAN", true}])

    assert run_queue(dir, ["1@aaa", "2@bbb"]) ==
             {"#1 head moved from aaa to zzz\nnot attempted: 2@bbb\n", 1}

    assert merges(dir) == []
  end

  test "a push while GitHub computes mergeability stops the queue unmerged", %{dir: dir} do
    pr(dir, 1, [{"aaa", "UNKNOWN", true}, {"zzz", "CLEAN", true}])

    assert run_queue(dir, ["1@aaa"]) ==
             {"#1 head moved from aaa to zzz\nnot attempted:\n", 1}

    assert merges(dir) == []
  end

  test "a PR that is no longer open stops the queue without watching checks", %{dir: dir} do
    pr(dir, 1, [{"aaa", "CLEAN", true, "MERGED"}])

    assert run_queue(dir, ["1"]) == {"#1 is MERGED\nnot attempted:\n", 1}
    assert calls(dir, "pr checks") == []
    assert merges(dir) == []
  end

  test "a PR gh cannot read stops the queue with gh's error", %{dir: dir} do
    assert run_queue(dir, ["9"]) ==
             {"#9 could not be read\nGraphQL: Could not resolve to a PullRequest with the number of 9.\nnot attempted:\n",
              1}
  end

  test "a wait GitHub never finishes times out instead of hanging the queue", %{dir: dir} do
    pr(dir, 1, [{"aaa", "UNKNOWN", true}])
    pr(dir, 2, [{"bbb", "CLEAN", false}])

    assert run_queue(dir, ["1", "2"], [{"MERGE_QUEUE_TIMEOUT", "0"}]) ==
             {"#1 timed out waiting for GitHub to compute mergeability\nnot attempted: 2\n", 1}

    assert run_queue(dir, ["2"], [{"MERGE_QUEUE_TIMEOUT", "0"}]) ==
             {"#2 timed out waiting for checks to register\nnot attempted:\n", 1}
  end

  test "a merge still pending when the wait runs out stops the queue", %{dir: dir} do
    pr(dir, 1, [{"aaa", "CLEAN", true}])
    File.write!(Path.join(dir, "merge-out-1"), ~s({"status":"pending","details":{"uuid":"u1"}}\n))

    assert run_queue(dir, ["1"], [{"MERGE_QUEUE_TIMEOUT", "0"}]) ==
             {"#1 timed out waiting for GitHub to finish the merge\nnot attempted:\n", 1}
  end

  test "a merge response that is not JSON is not reported as refused", %{dir: dir} do
    pr(dir, 1, [{"aaa", "CLEAN", true}])
    File.write!(Path.join(dir, "merge-out-1"), "warning: something odd\n")

    assert run_queue(dir, ["1"]) ==
             {"#1 merge result could not be read\nwarning: something odd\nnot attempted:\n", 1}
  end

  test "a merged PR whose remote branch cannot be deleted still lets the queue continue",
       %{dir: dir} do
    pr(dir, 1, [{"aaa", "CLEAN", true}])
    pr(dir, 2, [{"bbb", "CLEAN", true}])
    File.write!(Path.join(dir, "delete-status"), "1")

    assert run_queue(dir, ["1", "2"]) ==
             {"#1 merged sq1 (remote branch claude/aaa not deleted)\n" <>
                "#2 merged sq2 (remote branch claude/bbb not deleted)\n", 0}
  end

  test "a conflict with main stops the queue before later PRs", %{dir: dir} do
    pr(dir, 3, [{"ddd", "DIRTY", true}])
    pr(dir, 4, [{"eee", "CLEAN", true}])

    assert {out, 1} = run_queue(dir, ["3", "4"])

    assert ["#3 conflicts with main", json, "not attempted: 4"] =
             String.split(out, "\n", trim: true)

    assert %{"mergeable" => "CONFLICTING", "headRefName" => "claude/ddd"} = JSON.decode!(json)
    assert merges(dir) == []
  end

  test "a failing check stops the queue with the checks output", %{dir: dir} do
    pr(dir, 5, [{"fff", "BLOCKED", true}])
    File.write!(Path.join(dir, "checks-status-5"), "1")

    assert run_queue(dir, ["5", "6"]) ==
             {"#5 checks failed\ntest\tfail\t4m2s\thttps://github.com/o/r/actions/runs/1/job/2\nnot attempted: 6\n",
              1}

    assert merges(dir) == []
  end

  test "a gh error while watching checks is not reported as failed checks", %{dir: dir} do
    pr(dir, 5, [{"fff", "BLOCKED", true}])
    File.write!(Path.join(dir, "checks-status-5"), "1")
    File.write!(Path.join(dir, "watch-out-5"), "HTTP 502: Bad Gateway\n")
    File.write!(Path.join(dir, "checks-table-5"), "test\tpending\t0\thttps://x\n")

    assert run_queue(dir, ["5"]) ==
             {"#5 checks could not be watched\nHTTP 502: Bad Gateway\nnot attempted:\n", 1}

    assert merges(dir) == []
  end

  test "a push while checks run stops the queue as an unreviewed head", %{dir: dir} do
    pr(dir, 7, [{"hhh", "BLOCKED", true}, {"iii", "BLOCKED", true}])

    assert run_queue(dir, ["7@hhh"]) ==
             {"#7 head moved from hhh to iii\nnot attempted:\n", 1}

    assert merges(dir) == []
  end

  test "a merge GitHub refuses stops the queue with gh's message", %{dir: dir} do
    pr(dir, 6, [{"ggg", "CLEAN", true}])
    File.write!(Path.join(dir, "merge-status-6"), "1")

    File.write!(
      Path.join(dir, "merge-out-6"),
      "gh: Head branch was modified. Review and try the merge again. (HTTP 409)\n"
    )

    assert run_queue(dir, ["6"]) ==
             {"#6 merge refused\ngh: Head branch was modified. Review and try the merge again. (HTTP 409)\nnot attempted:\n",
              1}

    assert calls(dir, "api -X DELETE") == []
  end

  test "a merge that fails in GitHub's background processing stops the queue", %{dir: dir} do
    pr(dir, 6, [{"ggg", "CLEAN", true}])
    out = ~s({"status":"failed","details":{"message":"Required status check failed"}})
    File.write!(Path.join(dir, "merge-out-6"), out <> "\n")

    assert run_queue(dir, ["6"]) == {"#6 merge refused\n#{out}\nnot attempted:\n", 1}
    assert calls(dir, "api -X DELETE") == []
  end
end
