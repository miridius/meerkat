defmodule Meerkat.MergeQueueTest do
  # Runs scripts/merge-queue.sh against a stub `gh` on PATH. The stub answers
  # each `gh pr view` with the next JSON line from that PR's fixture (the last
  # line repeats) and applies the script's own `-q` filter with jq, so the
  # script's reading of real `gh` JSON is exercised too.
  use ExUnit.Case, async: true

  @script Path.expand("scripts/merge-queue.sh")

  setup do
    dir = Meerkat.TestHelpers.make_tmp_repo("meerkat-merge-queue")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(Path.join(dir, "bin"))
    gh = Path.join([dir, "bin", "gh"])

    File.write!(gh, ~S"""
    #!/usr/bin/env bash
    dir=$(dirname "$0")/..
    echo "$*" >> "$dir/log"
    case "$1 $2" in
      "pr view")
        f="$dir/view-$3"
        head -n 1 "$f" > "$dir/line"
        if [ "$(wc -l < "$f")" -gt 1 ]; then tail -n +2 "$f" > "$f.next"; mv "$f.next" "$f"; fi
        q=""; prev=""
        for a in "$@"; do [ "$prev" = -q ] && q=$a; prev=$a; done
        if [ -n "$q" ]; then jq -r "$q" < "$dir/line"; else cat "$dir/line"; fi
        ;;
      "pr update-branch")
        cat "$dir/update-branch-out-$3" 2>/dev/null
        exit "$(cat "$dir/update-branch-status-$3" 2>/dev/null || echo 0)"
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
        ;;
      "api "*)
        jq=""; prev=""
        for a in "$@"; do [ "$prev" = --jq ] && jq=$a; prev=$a; done
        case "$2" in
          */commits/*) cat "$dir/verification" 2>/dev/null || echo "verified: true, reason: valid" ;;
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
    {:ok, dir: dir}
  end

  defp pr(dir, number, states) do
    lines = Enum.map(states, &(&1 |> view() |> JSON.encode!()))
    File.write!(Path.join(dir, "view-#{number}"), Enum.join(lines, "\n") <> "\n")
  end

  # `checks` is whether the head has any checks registered yet; their results
  # come from `gh pr checks --watch`, stubbed per PR with a checks-status file.
  defp view({head, merge_state, checks}) do
    checks = if checks, do: [%{name: "test", status: "IN_PROGRESS", conclusion: ""}], else: []

    %{
      state: "OPEN",
      headRefOid: head,
      headRefName: "claude/#{head}",
      mergeStateStatus: merge_state,
      mergeable: if(merge_state == "DIRTY", do: "CONFLICTING", else: "MERGEABLE"),
      url: "https://github.com/o/r/pull/1",
      statusCheckRollup: checks
    }
  end

  defp run_queue(dir, prs) do
    env = [
      {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
      {"MERGE_QUEUE_POLL", "0"}
    ]

    System.cmd("bash", [@script | prs], env: env, stderr_to_stdout: true)
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

    assert calls(dir, "pr update-branch") == []
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
             {"#1 has open PRs below it in its stack: #2\nnot attempted: none\n", 1}

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

  test "a PR behind main is updated once, then merged at the new head after its checks",
       %{dir: dir} do
    pr(dir, 1, [{"aaa", "CLEAN", true}])

    pr(dir, 2, [
      {"bbb", "BEHIND", true},
      {"bbb", "BEHIND", true},
      {"ccc", "UNKNOWN", false},
      {"ccc", "BLOCKED", false},
      {"ccc", "BLOCKED", true}
    ])

    assert run_queue(dir, ["1", "2"]) == {"#1 merged sq1\n#2 merged sq2 (updated with main)\n", 0}

    assert calls(dir, "pr update-branch") == ["pr update-branch 2"]
    assert Enum.any?(log(dir), &(&1 =~ "commits/ccc"))

    # Only once the new head has checks registered are they watched.
    assert calls(dir, "pr view 2") |> length() == 6
    assert calls(dir, "pr checks 2") == ["pr checks 2 --watch --fail-fast --interval 0"]

    assert merges(dir) == [merge(1, "aaa"), merge(2, "ccc")]

    assert Enum.find_index(log(dir), &(&1 =~ "pulls/1/merge-async")) <
             Enum.find_index(log(dir), &(&1 =~ "pr update-branch 2"))
  end

  test "a PR given with its reviewed SHA is updated and merged while its head is that SHA",
       %{dir: dir} do
    pr(dir, 1, [{"aaa", "BEHIND", true}, {"bbb", "CLEAN", true}])

    assert run_queue(dir, ["1@aaa"]) == {"#1 merged sq1 (updated with main)\n", 0}
    assert merges(dir) == [merge(1, "bbb")]
  end

  test "a PR whose head moved past its reviewed SHA stops the queue unmerged", %{dir: dir} do
    pr(dir, 1, [{"zzz", "CLEAN", true}])

    assert run_queue(dir, ["1@aaa", "2@bbb"]) ==
             {"#1 head zzz is not the reviewed aaa\nnot attempted: 2@bbb\n", 1}

    assert merges(dir) == []
  end

  test "an update commit GitHub did not sign stops the queue", %{dir: dir} do
    pr(dir, 1, [{"aaa", "BEHIND", true}, {"bbb", "CLEAN", true}])
    File.write!(Path.join(dir, "verification"), "verified: false, reason: unsigned\n")

    assert {out, 1} = run_queue(dir, ["1"])

    assert out ==
             "#1 update commit bbb is not verified\nverified: false, reason: unsigned\nnot attempted: none\n"

    assert merges(dir) == []
  end

  test "a conflict with main stops the queue before later PRs", %{dir: dir} do
    pr(dir, 3, [{"ddd", "DIRTY", true}])
    pr(dir, 4, [{"eee", "CLEAN", true}])

    assert {out, 1} = run_queue(dir, ["3", "4"])

    assert ["#3 conflicts with main", json, "not attempted: 4"] =
             String.split(out, "\n", trim: true)

    assert %{"mergeable" => "CONFLICTING", "headRefName" => "claude/ddd"} = JSON.decode!(json)
    assert merges(dir) == []
    assert calls(dir, "pr update-branch") == []
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
             {"#5 checks could not be watched\nHTTP 502: Bad Gateway\nnot attempted: none\n", 1}

    assert merges(dir) == []
  end

  test "a push while checks run stops the queue as an unreviewed head", %{dir: dir} do
    pr(dir, 7, [{"hhh", "BLOCKED", true}, {"iii", "BLOCKED", true}])

    assert run_queue(dir, ["7@hhh"]) ==
             {"#7 head iii is not the reviewed hhh\nnot attempted: none\n", 1}

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
             {"#6 merge refused\ngh: Head branch was modified. Review and try the merge again. (HTTP 409)\nnot attempted: none\n",
              1}

    assert calls(dir, "api -X DELETE") == []
  end

  test "a merge that fails in GitHub's background processing stops the queue", %{dir: dir} do
    pr(dir, 6, [{"ggg", "CLEAN", true}])
    out = ~s({"status":"failed","details":{"message":"Required status check failed"}})
    File.write!(Path.join(dir, "merge-out-6"), out <> "\n")

    assert run_queue(dir, ["6"]) == {"#6 merge refused\n#{out}\nnot attempted: none\n", 1}
    assert calls(dir, "api -X DELETE") == []
  end
end
