defmodule Meerkat.CLI do
  @moduledoc """
  Command-line entry point.

  Usage:

      meerkat                              # review staged diff
      meerkat --commit-msg <PATH>          # staged diff + commit-msg gutter
      meerkat HEAD                         # single ref → REF~1...REF
      meerkat A..B                         # two-dot range
      meerkat A...B                        # three-dot range (merge-base)
      meerkat --pr <N>                     # GitHub PR via `gh`

  Flags: `--no-open`, `--port <N>`.

  Behaviour is locked in by the Playwright spec suite in `tests/e2e/`.
  Empty-staged-diff auto-approve (the binary exits 0 before binding
  the server) only fires for `--commit-msg`-and-no-positional
  invocations — the commit-msg hook path.
  """

  alias Meerkat.{
    ApprovalCache,
    Decision,
    Feedback,
    Git,
    PendingAnswers,
    Persistence,
    ReviewId,
    ReviewLog,
    ReviewServer,
    ReviewState,
    ReviewTarget
  }

  # Compile-time env so release builds don't need `Mix` at runtime.
  @env Mix.env()

  @type opts :: %{
          commit_msg_path: String.t() | nil,
          positional: String.t() | nil,
          pr: String.t() | nil,
          no_open: boolean(),
          port: non_neg_integer()
        }

  @doc """
  Entry point invoked by `bin/meerkat-beam` and the installed prod
  release. Returns the exit code; the caller is responsible for
  `System.halt/1`.

  ## Safety invariant: default-deny on crash

  The only path to exit-0 is an explicit `{:approve, _}` /
  `{:approve_with_feedback, _}` from a button click — or the
  auto-approve fast path with its visible "auto-approving" stderr
  breadcrumb. Anything else (Decision GenServer crash, ReviewServer
  crash, unhandled exception, endpoint failure, supervisor restart)
  must bubble out as a non-zero exit so the git hook ABORTS the
  commit. Two layers of `try / rescue / catch` enforce that: any
  error / throw / exit anywhere downstream of `main/1` lands as
  exit code 2.
  """
  @spec main([String.t()]) :: non_neg_integer()
  def main(argv) do
    opts = parse_args(argv)
    target = ReviewTarget.from_opts(opts)

    case auto_approve_decision(target, repo_path()) do
      {:auto, message} ->
        IO.write(:stderr, message)
        finalise_auto_approve(repo_path())
        0

      :live ->
        run_live_review_safe(target, opts)
    end
  rescue
    e ->
      IO.puts(
        :stderr,
        "meerkat: unhandled exception in CLI main — defaulting to REJECT (commit aborted).\n" <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      2
  catch
    kind, reason ->
      IO.puts(
        :stderr,
        "meerkat: caught #{inspect(kind)} #{inspect(reason)} in CLI main — " <>
          "defaulting to REJECT (commit aborted)."
      )

      2
  after
    flush_logs()
  end

  # filesync the log file handler before the launcher calls
  # `System.halt/1` — halt tears the VM down without running handler
  # terminate callbacks, so the `:logger_std_h` buffer (which holds the
  # endpoint banner + request logs) would otherwise be discarded
  # unwritten. Guarded: a no-op when the handler was never installed
  # (auto-approve fast path) and swallows any flush error, because this
  # runs at teardown and must never flip an already-decided exit code.
  defp flush_logs do
    case :logger.get_handler_config(:meerkat_file) do
      {:ok, _} -> :logger_std_h.filesync(:meerkat_file)
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp run_live_review_safe(target, opts) do
    try do
      run_live_review(target, opts)
    rescue
      e ->
        IO.puts(
          :stderr,
          "meerkat: live-review crashed — defaulting to REJECT (commit aborted).\n" <>
            Exception.format(:error, e, __STACKTRACE__)
        )

        2
    catch
      kind, reason ->
        IO.puts(
          :stderr,
          "meerkat: live-review caught #{inspect(kind)} #{inspect(reason)} — " <>
            "defaulting to REJECT (commit aborted)."
        )

        2
    end
  end

  defp run_live_review(target, opts) do
    case ReviewState.from_target(target, repo_path()) do
      {:ok, state} ->
        prune_approval_cache(repo_path())
        review_id = ReviewId.derive(repo_path(), target)
        log = ReviewLog.start(repo_path(), state)
        start_endpoint!(opts.port, state, review_id, repo_path())
        announce_url(target)
        open_browser_unless_disabled(opts.no_open)
        decision = await_decision_or_reject()
        # Give the LiveView a moment to flush the done-view
        # assigns update to the browser before the BEAM dies.
        Process.sleep(750)
        {tag, payload} = decision
        _ = ReviewLog.finalize(log, decision_atom(tag), to_string(payload))
        # Clear the in-progress snapshot — the next invocation must
        # start with an empty review, not replay stale comments from
        # a closed cycle.
        _ = Persistence.delete(repo_path(), review_id)
        exit_code(decision, review_id, feedback_file_path(log))

      {:error, reason} ->
        IO.puts(:stderr, "meerkat: error resolving review target: #{reason}")
        2
    end
  end

  # `Decision.await/0` raises an exit if the Decision GenServer
  # dies mid-call; that propagates out and the surrounding
  # try/catch in `run_live_review_safe` converts it to exit 2.
  # The up-front `Process.whereis/1` check turns the "Decision was
  # never started" failure mode into a clear REJECT instead of a
  # cryptic stack trace.
  defp await_decision_or_reject do
    case Process.whereis(Decision) do
      nil ->
        IO.puts(
          :stderr,
          "meerkat: Decision GenServer not running — defaulting to REJECT (commit aborted)."
        )

        {:cancel, ""}

      _pid ->
        Decision.await()
    end
  end

  # Drop approval-cache entries for branches that no longer exist
  # locally. Runs once per hook invocation. On git failure (e.g.
  # corrupt repo) skip — never wipe the cache treating "no branches"
  # as truth.
  defp prune_approval_cache(repo_path) do
    with path when is_binary(path) <- ApprovalCache.path_for(repo_path),
         {:ok, branches} <- Git.local_branches(repo_path) do
      _ = ApprovalCache.modify(path, &ApprovalCache.prune(&1, branches))
      :ok
    else
      _ -> :ok
    end
  end

  ## Argument parsing

  @switches [
    commit_msg: :string,
    pr: :string,
    no_open: :boolean,
    port: :integer
  ]

  @spec parse_args([String.t()]) :: opts
  def parse_args(argv) do
    {parsed, positional, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: [])

    case args_error(positional, invalid) do
      nil ->
        %{
          commit_msg_path: Keyword.get(parsed, :commit_msg),
          positional: List.first(positional),
          pr: Keyword.get(parsed, :pr),
          no_open: Keyword.get(parsed, :no_open, false),
          port: Keyword.get(parsed, :port, 0)
        }

      message ->
        IO.puts(:stderr, message)
        System.halt(2)
    end
  end

  # `nil` when the parsed argv is well-formed; otherwise the stderr
  # message explaining the rejection. Pure, so the rejection rules are
  # unit-testable without `parse_args/1`'s `System.halt/1`.
  @doc false
  def args_error(positional, invalid) do
    cond do
      invalid != [] ->
        "meerkat: unrecognised options: " <>
          Enum.map_join(invalid, ", ", fn {flag, _} -> flag end)

      length(positional) > 1 ->
        "meerkat: at most one positional ref-or-range argument; got: #{Enum.join(positional, " ")}"

      true ->
        nil
    end
  end

  ## Staged-diff auto-approve fast path
  #
  # Skip the UI when every staged file is either linguist-generated
  # (lockfiles, vendored bundles — the UI hides them by default and the
  # reviewer has nothing meaningful to look at) or content-addressed
  # already-approved by this branch's reviewer in a previous round. The
  # empty staged set qualifies vacuously (e.g. `git commit --amend`
  # editing only the message). For range / single-ref / PR targets the
  # user asked for a *specific* diff — even if empty they get the UI.

  @spec auto_approve_decision(ReviewTarget.t(), String.t()) :: :live | {:auto, String.t()}
  defp auto_approve_decision({:staged, _}, repo_path) do
    case Git.staged_files(repo_path) do
      {:ok, []} ->
        {:auto, "meerkat: no staged file changes — auto-approving.\n"}

      {:ok, files} ->
        cache = ApprovalCache.load_for(repo_path)
        branch = Git.current_branch(repo_path)
        names = Enum.map(files, & &1.file_name)

        generated_map = Git.linguist_generated_many(repo_path, names)
        # One batched `git ls-files -s` for all paths instead of N+1.
        # On batched failure we fall through to `:live` (rather than
        # silently auto-approving with stale-OID data) — the warning
        # is already logged by `staged_blob_oids_many`.
        oid_map =
          case Git.staged_blob_oids_many(repo_path, names) do
            {:ok, map} -> map
            {:error, _} -> %{}
          end

        verdicts =
          Enum.map(files, fn entry ->
            classify_for_auto_approve(entry, cache, branch, generated_map, oid_map)
          end)

        decide_from_verdicts(verdicts, length(files))

      {:error, reason} ->
        IO.puts(
          :stderr,
          "meerkat: warning — couldn't list staged files for auto-approve check (#{reason}); " <>
            "falling through to live review."
        )

        :live
    end
  end

  defp auto_approve_decision(_target, _repo_path), do: :live

  # Map per-file verdicts to the auto-approve decision. Split out of
  # `auto_approve_decision/2` so the safety guard — never auto-approve
  # when any file is `:neither` (still needs human review) — is
  # unit-testable without standing up a staged git fixture.
  defp decide_from_verdicts(verdicts, total) do
    cond do
      Enum.all?(verdicts, &(&1 == :generated)) ->
        {:auto, "meerkat: all #{total} staged file(s) are linguist-generated — auto-approving.\n"}

      Enum.all?(verdicts, &(&1 in [:approved, :generated])) and
          Enum.any?(verdicts, &(&1 == :approved)) ->
        approved = Enum.count(verdicts, &(&1 == :approved))
        generated = Enum.count(verdicts, &(&1 == :generated))

        msg =
          if generated == 0 do
            "meerkat: all #{total} staged file(s) already approved — auto-approving.\n"
          else
            "meerkat: all #{total} staged file(s) already approved (#{approved}) or linguist-generated (#{generated}) — auto-approving.\n"
          end

        {:auto, msg}

      true ->
        :live
    end
  end

  # `:approved` | `:generated` | `:neither`. `generated_map` is the
  # batched output of `Git.linguist_generated_many/2` — one git
  # check-attr call for the whole staged set, error info preserved
  # per file so a transient git failure can't fake `:generated`.
  #
  # `:approved` checks the current staged blob OID against the
  # per-branch cache so a flip-flopping file keeps its tick. `nil`
  # branch (detached HEAD) -> can't match an approval, but
  # `:generated` is branch-independent and still fires.
  defp classify_for_auto_approve(
         %{file_name: name, status: :deleted},
         _cache,
         _branch,
         generated_map,
         _oid_map
       ) do
    # Deletion has no new blob to content-address against, so only
    # the generated half applies — and you only care about
    # generated-file deletions (regenerated lockfile removed from
    # the tree).
    if generated?(generated_map, name), do: :generated, else: :neither
  end

  defp classify_for_auto_approve(
         %{file_name: name},
         cache,
         branch,
         generated_map,
         oid_map
       ) do
    cond do
      generated?(generated_map, name) ->
        :generated

      not is_nil(branch) and
          ApprovalCache.approved?(cache, branch, name, Map.get(oid_map, name, "")) ->
        :approved

      true ->
        :neither
    end
  end

  # Treat `{:error, _}` and missing entries as "not generated" — a
  # transient git failure must never short-circuit the UI as
  # auto-approve. The batched lookup itself logs the error.
  defp generated?(generated_map, name) do
    case Map.get(generated_map, name) do
      {:generated, bool} -> bool
      _ -> false
    end
  end

  # Test seams for the pure auto-approve logic — let cli_test.exs exercise
  # the per-file classifier and the verdict decision without standing up
  # a staged git fixture. Mirrors git.ex's `parse_multi_file_diff_for_test/1`.
  @doc false
  def classify_for_auto_approve_for_test(entry, cache, branch, generated_map, oid_map),
    do: classify_for_auto_approve(entry, cache, branch, generated_map, oid_map)

  @doc false
  def decide_from_verdicts_for_test(verdicts, total), do: decide_from_verdicts(verdicts, total)

  @doc false
  def feedback_banner_for_test(count, save_result), do: feedback_banner(count, save_result)

  @doc false
  def pause_banner_for_test(target, url), do: pause_banner(target, url)

  @doc false
  def write_feedback_for_test(payload, review_id, feedback_path),
    do: write_feedback(payload, review_id, feedback_path)

  @doc false
  def feedback_file_path_for_test(log), do: feedback_file_path(log)

  @doc false
  def comment_count_for_test(review_id), do: comment_count(review_id)

  @doc false
  def repo_path_for_test, do: repo_path()

  @doc false
  def endpoint_config_for_test(port), do: endpoint_config(port)

  @doc false
  def secret_key_base_for_test, do: secret_key_base()

  # On a successful auto-approve, clear the pending-answers banner the
  # next live review would otherwise pin from a stale prior round.
  defp finalise_auto_approve(repo_path) do
    PendingAnswers.clear(repo_path)
    :ok
  end

  defp repo_path do
    # `bin/meerkat-beam` cd's into the Mix root before invoking the
    # CLI; the launcher re-cd's via $MEERKAT_PWD. Use that env var
    # if present so git operations target the user's cwd, not the
    # Mix project.
    System.get_env("MEERKAT_PWD") || File.cwd!()
  end

  ## Endpoint startup

  defp start_endpoint!(requested_port, %ReviewState{} = state, review_id, repo_path) do
    # `meerkat_dir` resolution shells out to `git rev-parse`; do it
    # once here so every save/load through the lifetime of this BEAM
    # doesn't re-fork-and-exec just to discover the same path.
    meerkat_dir = Git.meerkat_dir(repo_path)

    # Application env carries the derived target + initial state into
    # `ReviewLive.mount/3`. The LiveView then calls
    # `ReviewServer.ensure_started/2` with these, after which the
    # GenServer owns the canonical state and the LV reads from it.
    Application.put_env(:meerkat, :review_id, review_id)
    Application.put_env(:meerkat, :repo_path, repo_path)
    Application.put_env(:meerkat, :meerkat_dir, meerkat_dir)
    Application.put_env(:meerkat, :review_state, state)
    Application.put_env(:meerkat, :start_endpoint, true)
    Application.put_env(:meerkat, MeerkatWeb.Endpoint, endpoint_config(requested_port))

    # Redirect Phoenix/Bandit/LiveView Logger output to a file BEFORE the
    # endpoint boots — the "Running MeerkatWeb.Endpoint" banner fires
    # inside `ensure_all_started` — so the agent-facing stream carries
    # only the URL + verdict, not 40+ lines of server log.
    Application.put_env(:meerkat, :log_path, redirect_logs_to_file(meerkat_dir))
    {:ok, _} = Application.ensure_all_started(:meerkat)
  end

  # Route Logger output to `<meerkat_dir>/meerkat.log` and return the
  # path. Reuses the default handler's formatter so the configured log
  # format carries over, then swaps the destination to a file. Adds the
  # file handler BEFORE removing `:default` so an add failure leaves
  # console logging intact for the crash output.
  #
  # Deliberately NOT defensive: a failure here (can't make the dir,
  # can't open the file, handler already installed) is genuine breakage,
  # so it raises and meerkat's top-level default-deny handler turns it
  # into a loud exit-2 commit abort + stack trace — surfaced and fixed,
  # not silently degraded into "logs went nowhere".
  defp redirect_logs_to_file(meerkat_dir) do
    log_path = Path.join(meerkat_dir, "meerkat.log")
    File.mkdir_p!(meerkat_dir)
    {:ok, %{formatter: formatter}} = :logger.get_handler_config(:default)

    :ok =
      :logger.add_handler(:meerkat_file, :logger_std_h, %{
        config: %{type: {:file, String.to_charlist(log_path)}},
        formatter: formatter
      })

    :ok = :logger.remove_handler(:default)
    log_path
  end

  defp endpoint_config(requested_port) do
    base = Application.get_env(:meerkat, MeerkatWeb.Endpoint, [])

    # Prod (mix release): override dev.exs's runtime checks with
    # one-shot CLI flags.
    # Dev (`bin/meerkat-beam` + MIX_ENV=dev): keep dev.exs intact.
    # Source-change reloads come from `Meerkat.DevWatcher` halting
    # the BEAM and the shepherd respawning it, not from Phoenix's
    # request-time code reloader (which is off in dev too).
    prod_overrides = [
      code_reloader: false,
      debug_errors: false,
      live_reload: nil,
      watchers: [],
      static_url: nil
    ]

    always = [
      http: [ip: {127, 0, 0, 1}, port: requested_port],
      server: true,
      secret_key_base: secret_key_base(),
      check_origin: {MeerkatWeb.Loopback, :origin?, []}
    ]

    if @env == :dev do
      Keyword.merge(base, always)
    else
      Keyword.merge(base, always ++ prod_overrides)
    end
  end

  defp secret_key_base do
    System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))
  end

  # The opening banner is written for the AGENT whose `git commit` (or
  # ad-hoc `meerkat` invocation) is now blocked on a human: it has to
  # say what the pause means, that waiting is the correct move, and how
  # to read the outcome — otherwise agents poll, sleep, or give up on
  # the "stuck" process. Wording is target-aware: only a staged review
  # WITH a commit-msg path is the commit-msg hook flow where exit 0
  # lands a commit; a bare `meerkat` staged run and the ad-hoc
  # ref/range/PR modes land nothing on approve.
  defp pause_banner(target, url) do
    {process_desc, exit_zero} =
      case target do
        {:staged, path} when not is_nil(path) -> {"`git commit` process", "approved & landed"}
        _ -> {"`meerkat` process", "approved"}
      end

    """
    ⏸ Paused for human review at #{url} — may take minutes or hours.
    Agents: this #{process_desc} blocks until the review completes, then exits
    on its own — do NOT poll, sleep, or schedule wake-ups; just wait for the exit.
    Exit 0 = #{exit_zero}, exit 1 = changes requested. In BOTH cases read the
    full process output afterwards: approvals can still carry review comments, and
    rejections include the feedback you must address.
    """
  end

  defp announce_url(target) do
    IO.write(:stderr, pause_banner(target, review_url()))
    IO.puts(:stderr, "debug logs at: #{Application.get_env(:meerkat, :log_path)}")
  end

  defp open_browser_unless_disabled(true), do: :ok

  defp open_browser_unless_disabled(false) do
    # Shepherd-managed marker so a DevWatcher restart doesn't spawn a
    # duplicate tab. The shepherd creates the file empty; we check
    # for non-empty contents on every call and only open + stamp it
    # on the very first invocation. Absent env var = no shepherd, so
    # we just open (the prod release path).
    case marker_state() do
      :already_opened ->
        :ok

      :first_open ->
        do_open_browser()
    end
  end

  defp marker_state do
    case System.get_env("MEERKAT_OPEN_MARKER") do
      nil ->
        :first_open

      path ->
        case File.read(path) do
          {:ok, "1" <> _} -> :already_opened
          _ -> :first_open
        end
    end
  end

  defp stamp_marker do
    case System.get_env("MEERKAT_OPEN_MARKER") do
      nil ->
        :ok

      path ->
        case File.write(path, "1\n") do
          :ok ->
            :ok

          {:error, reason} ->
            # Best-effort: if the marker write fails the next shepherd
            # iteration sees an empty marker and re-opens the browser,
            # producing a duplicate tab. We log so the operator can
            # see the race, but the duplicate tab is the known-degraded
            # outcome — better than crashing the LV.
            IO.puts(
              :stderr,
              "meerkat: warning — couldn't stamp browser-open marker at #{path}: " <>
                "#{inspect(reason)} (may re-open browser on next restart)"
            )

            :ok
        end
    end
  end

  defp do_open_browser do
    url = review_url()

    case Meerkat.Browser.open(url) do
      :ok ->
        stamp_marker()
        :ok

      {:error, reason} ->
        IO.puts(
          :stderr,
          "meerkat: couldn't auto-open browser (#{reason}). Open #{url} manually."
        )

        :ok
    end
  end

  # Pull the actually-bound port from the running endpoint. Bandit
  # exposes it via Phoenix.Endpoint.server_info/1, which the
  # documented spec returns `{:ok, {ip, port}}` on. This is the only
  # way to honour `--port 0` (OS-assigned).
  defp review_url do
    case MeerkatWeb.Endpoint.server_info(:http) do
      {:ok, {_ip, port}} ->
        "http://127.0.0.1:#{port}/"

      # Older Phoenix shapes / unexpected returns: fall back to the
      # configured value rather than crash. Logged so a regression
      # surfaces.
      other ->
        IO.puts(
          :stderr,
          "meerkat: warning — unable to read bound port from endpoint (#{inspect(other)})"
        )

        port = Application.get_env(:meerkat, MeerkatWeb.Endpoint)[:http][:port] || 0
        "http://127.0.0.1:#{port}/"
    end
  end

  ## Exit code mapping
  #
  # Every terminal decision prints a plain, user-attributed sentence to
  # stderr — no path is silent, because a silent exit reads as a crash
  # to the calling agent. Approve-with-feedback / Reject surface the
  # payload (Feedback.format/3's output), which already opens with its
  # own user-attributed framing, so they add no extra line here. Cancel
  # wiped its comments before submit (payload is ""), so its sentence is
  # all the agent gets — and now it gets one.

  defp exit_code({:approve, _payload}, _review_id, _feedback_path) do
    IO.puts(:stderr, "The user approved your commit. Proceeding.")
    0
  end

  defp exit_code({:approve_with_feedback, payload}, review_id, feedback_path) do
    write_feedback(payload, review_id, feedback_path)
    0
  end

  defp exit_code({:reject, payload}, review_id, feedback_path) do
    write_feedback(payload, review_id, feedback_path)
    1
  end

  defp exit_code({:cancel, _payload}, _review_id, _feedback_path) do
    IO.puts(:stderr, "Review cancelled — commit aborted, no feedback to act on.")
    1
  end

  defp decision_atom(:approve_with_feedback), do: :approve
  defp decision_atom(tag), do: tag

  # Sibling of the review-log file — a fixed name would be clobbered by
  # a concurrent review on the same gitdir.
  defp feedback_file_path(%ReviewLog{path: log_path}), do: Path.rootname(log_path) <> ".txt"

  defp write_feedback("", _review_id, _feedback_path), do: :ok

  # Bracket the feedback top and bottom: the agent often head/tail's
  # this stream, so whichever end survives still carries count + path.
  defp write_feedback(payload, review_id, feedback_path) when is_binary(payload) do
    banner = feedback_banner(comment_count(review_id), save_feedback_file(payload, feedback_path))
    IO.write(:stderr, banner)
    IO.write(:stderr, payload)
    IO.write(:stderr, banner)
    :ok
  end

  # Best-effort: on failure yield nil so the banner omits the count
  # rather than printing a wrong "0" or aborting an already-decided commit.
  defp comment_count(review_id) do
    Feedback.comment_count(ReviewServer.get_state(review_id))
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Best-effort: a failed write must never flip an already-decided exit code.
  defp save_feedback_file(payload, path) do
    case File.write(path, payload) do
      :ok -> {:ok, path}
      {:error, reason} -> feedback_file_unsaved(path, reason)
    end
  rescue
    e -> feedback_file_unsaved(path, e)
  end

  # Surface the reason — swallowing it leaves the agent with no recovery
  # copy and no clue why.
  defp feedback_file_unsaved(path, reason) do
    IO.puts(
      :stderr,
      "meerkat: warning — couldn't save full feedback to #{path} (#{inspect(reason)})."
    )

    :error
  end

  # User-attributed, not tool-attributed: a "meerkat:" label next to
  # first-party feedback would read as a third-party verdict.
  defp feedback_banner(count, save_result) do
    "\n── #{count_phrase(count)} — #{file_phrase(save_result)} ──\n"
  end

  defp count_phrase(count) when is_integer(count),
    do: "User left #{count} comment#{if count == 1, do: "", else: "s"} total"

  defp count_phrase(_), do: "User left comments"

  defp file_phrase({:ok, path}), do: "full feedback saved to #{path} in case truncated"
  defp file_phrase(:error), do: "full feedback could not be written to disk"
end
