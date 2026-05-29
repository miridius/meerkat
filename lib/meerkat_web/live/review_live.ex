defmodule MeerkatWeb.ReviewLive do
  @moduledoc """
  The single LiveView for the meerkat review UI.

  Comment forms attach on four surfaces: global (page-level), per-file,
  commit-msg gutter, and inline per-line (anchored via pointer-drag
  selection in `DiffViewer.svelte`).

  Form state is in-LV (which surface is open, edit_id if editing
  vs adding); comment data lives in the ReviewServer. Submissions
  delegate to `ReviewServer.add_*` / `remove_comment` so the
  GenServer stays the single writer. The `LiveSvelte` socket bridge
  round-trips the form's body / finding_type / learn_from_this from
  CommentForm.svelte.
  """

  use MeerkatWeb, :live_view

  alias Meerkat.{
    ApprovalCache,
    Comment,
    Decision,
    Feedback,
    GitHub,
    PendingAnswers,
    ReviewServer,
    ReviewState
  }

  @impl true
  def mount(_params, _session, socket) do
    initial_state = Application.get_env(:meerkat, :review_state) || %ReviewState{}
    repo_path = Application.get_env(:meerkat, :repo_path) || File.cwd!()
    review_id = Application.get_env(:meerkat, :review_id) || "unbound"

    state =
      if review_id == "unbound" do
        initial_state
      else
        {:ok, _pid} =
          ReviewServer.ensure_started(review_id, %{
            repo_path: repo_path,
            initial_state: initial_state
          })

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Meerkat.PubSub, ReviewServer.topic(review_id))
        end

        ReviewServer.get_state(review_id)
      end

    # Refresh-during-shutdown: if the CLI has already submitted a
    # decision (Decision.current/0 returns non-nil), seed the
    # `:done` assign so the LiveView mounts straight onto the done
    # view rather than the live review.
    done =
      case Decision.current() do
        {:approve, _} -> :approve
        {:approve_with_feedback, _} -> :approve
        {:reject, _} -> :reject
        {:cancel, _} -> :cancel
        nil -> nil
      end

    {:ok,
     assign(socket,
       page_title: page_title(state),
       state: state,
       diff_mode: "split",
       # Wrap long lines by default — horizontal scrolling forces the
       # reviewer off the keyboard and hides context. The toolbar
       # toggle still lets users opt out for code that genuinely
       # reads better unwrapped (long URLs, hex dumps).
       wrap_lines: true,
       font_size_px: 13,
       tab_size: 2,
       review_id: review_id,
       repo_path: repo_path,
       # Restore from persisted state — survives DevWatcher restart,
       # crash, or close-and-reopen of the browser tab.
       open_form: Map.get(state, :open_form, nil),
       filter_input: "",
       only_file_index: nil,
       # File-filter sidebar is closed by default so the diff body
       # uses the full viewport width. Toggle in the toolbar to
       # reveal the file list / filter / per-file approval ticks.
       files_panel_open: false,
       # File indices the reviewer has explicitly expanded after the
       # file was approved (which collapses the diff body by default).
       # Click the file header to flip collapse state; the set is
       # ephemeral — un-approving + re-approving collapses again.
       expanded_approved: MapSet.new(),
       # File names the user has explicitly collapsed despite the
       # file NOT being approved. Approved files default to collapsed
       # (and get expanded via `expanded_approved`); unapproved files
       # default to expanded (and get collapsed via this set).
       collapsed_unapproved: MapSet.new(),
       # Cached at mount — drives the inline `.puml` preview's
       # available state. Component shows the diff preview when
       # true, an "install plantuml" hint when false.
       plantuml_available: Meerkat.PlantUML.available?(),
       done: done,
       # Transient error banner. Set by handlers that failed in a way
       # the user needs to see (gh api failure, stale-OID rejected
       # approve). Cleared on the next decision or by clicking the
       # close button on the banner.
       flash_error: nil,
       # Pinned pending-answers banner. Best-effort: nil if no file
       # / malformed / wrong schema version. Cleared on any
       # terminal decision via PendingAnswers.clear/1.
       pending_answers: PendingAnswers.load(repo_path)
     )}
  end

  defp page_title(%ReviewState{pr: %{number: n}}), do: "meerkat — PR ##{n}"
  defp page_title(%ReviewState{}), do: "meerkat commit review"

  # Write-through: update the LV assign AND persist to ReviewServer
  # so a BEAM restart (DevWatcher hot reload, crash) or a fresh tab
  # reconnect finds the same form open at the same anchor. Body
  # content is separately preserved by CommentForm's localStorage
  # draft.
  defp set_open_form(socket, form) do
    rid = socket.assigns.review_id
    if rid != "unbound", do: ReviewServer.set_open_form(rid, form)
    assign(socket, open_form: form)
  end

  defp toggle_member(set, key) do
    if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
  end

  defp push_settings(socket) do
    push_event(socket, "settings:save", %{
      diff_mode: socket.assigns.diff_mode,
      wrap_lines: socket.assigns.wrap_lines,
      font_size_px: socket.assigns.font_size_px,
      tab_size: socket.assigns.tab_size
    })
  end

  # Tell the Settings JS hook to drop every `meerkat:draft:<rid>:…`
  # entry from localStorage. Fired on every terminal decision so
  # stale per-anchor drafts don't pile up across reviews.
  defp wipe_drafts(socket) do
    rid = socket.assigns.review_id
    if rid == "unbound", do: socket, else: push_event(socket, "drafts:wipe", %{review_id: rid})
  end

  ## --- Diff toolbar ---

  @impl true
  def handle_event("set_diff_mode", %{"mode" => mode}, socket)
      when mode in ["split", "unified"] do
    socket = assign(socket, diff_mode: mode)
    {:noreply, push_settings(socket)}
  end

  def handle_event("toolbar.toggle_wrap", _, socket) do
    socket = assign(socket, wrap_lines: not socket.assigns.wrap_lines)
    {:noreply, push_settings(socket)}
  end

  def handle_event("toolbar.set_font_size", %{"px" => px}, socket) do
    case parse_int(px) do
      {:ok, n} ->
        {:noreply, push_settings(assign(socket, font_size_px: clamp_font_size(n)))}

      :error ->
        log_ignored_event("toolbar.set_font_size", "px", px)
        {:noreply, socket}
    end
  end

  def handle_event("toolbar.bump_font_size", %{"by" => by}, socket) do
    case parse_int(by) do
      {:ok, n} ->
        px = clamp_font_size(socket.assigns.font_size_px + n)
        {:noreply, push_settings(assign(socket, font_size_px: px))}

      :error ->
        log_ignored_event("toolbar.bump_font_size", "by", by)
        {:noreply, socket}
    end
  end

  def handle_event("toolbar.set_tab_size", %{"n" => n}, socket) do
    case parse_int(n) do
      {:ok, v} ->
        {:noreply, push_settings(assign(socket, tab_size: clamp_tab_size(v)))}

      :error ->
        log_ignored_event("toolbar.set_tab_size", "n", n)
        {:noreply, socket}
    end
  end

  # Hydrate toolbar prefs from the client's localStorage on mount.
  # The Settings JS hook reads `meerkat:settings` and dispatches this
  # once with whatever validated values it found; missing keys keep
  # the server defaults.
  def handle_event("settings.load", payload, socket) when is_map(payload) do
    {:noreply,
     assign(socket,
       diff_mode: valid_diff_mode(payload["diff_mode"], socket.assigns.diff_mode),
       wrap_lines: valid_bool(payload["wrap_lines"], socket.assigns.wrap_lines),
       font_size_px: valid_font_size(payload["font_size_px"], socket.assigns.font_size_px),
       tab_size: valid_tab_size(payload["tab_size"], socket.assigns.tab_size)
     )}
  end

  ## --- File approval ---

  def handle_event(
        "file.toggle_approved",
        %{"file_name" => file_name},
        %{assigns: %{review_id: rid, state: state, repo_path: repo_path}} = socket
      ) do
    approved? = MapSet.member?(state.approved_file_names, file_name)
    becoming_approved? = not approved?
    rendered_file = Enum.find(state.files, &(&1.file_name == file_name))

    case stale_oid_check(repo_path, rendered_file, becoming_approved?) do
      :ok ->
        if rid != "unbound" do
          _ = ReviewServer.set_approved(rid, file_name, becoming_approved?)
        end

        # Mirror into the global per-branch approval cache so future
        # hook runs on this branch can short-circuit the UI via the
        # staged-diff fast path. Best-effort: a write failure just
        # means the user re-ticks Approved next round — but we
        # surface the failure as a flash so the user knows the tick
        # isn't durable instead of finding out next session.
        persist_result =
          persist_approval_cache_toggle(
            repo_path,
            file_name,
            becoming_approved?,
            state.head_branch,
            state
          )

        socket =
          case persist_result do
            {:error, reason} ->
              assign(socket,
                flash_error:
                  "Approval tick for #{file_name} didn't persist " <>
                    "(#{inspect(reason)}). Re-tick next session if you want it cached."
              )

            _ ->
              assign(socket, flash_error: nil)
          end

        # On approve, the file section collapses — without this the
        # following file leaps up by ~viewport height. Push a client
        # event so the just-approved header re-anchors to the top of
        # the viewport.
        socket =
          if becoming_approved? do
            idx = Enum.find_index(state.files, &(&1.file_name == file_name))
            if idx, do: push_event(socket, "scroll-into-view", %{id: "file-#{idx}"}), else: socket
          else
            socket
          end

        {:noreply, socket}

      {:stale, msg} ->
        {:noreply, assign(socket, flash_error: msg)}
    end
  end

  ## --- Form open / close ---

  def handle_event("comment_form.show_global", _, socket) do
    {:noreply, set_open_form(socket, %{surface: :global, anchor: %{}})}
  end

  def handle_event("comment_form.show_file", %{"file_index" => idx}, socket) do
    case parse_int(idx) do
      {:ok, n} ->
        {:noreply, set_open_form(socket, %{surface: :file, anchor: %{file_index: n}})}

      :error ->
        log_ignored_event("comment_form.show_file", "file_index", idx)
        {:noreply, socket}
    end
  end

  def handle_event(
        "comment_form.show_commit_msg",
        %{"start_line" => from, "end_line" => to},
        socket
      ) do
    with {:ok, f} <- parse_int(from), {:ok, t} <- parse_int(to) do
      {:noreply,
       set_open_form(socket, %{
         surface: :commit_msg,
         anchor: %{start_line: f, end_line: t}
       })}
    else
      :error ->
        log_ignored_event("comment_form.show_commit_msg", "start_line/end_line", {from, to})
        {:noreply, socket}
    end
  end

  def handle_event(
        "comment_form.show_at_line",
        %{"file_index" => idx, "start_line" => from, "end_line" => to, "side" => side},
        socket
      )
      when side in ["old", "new"] do
    with {:ok, i} <- parse_int(idx),
         {:ok, f} <- parse_int(from),
         {:ok, t} <- parse_int(to) do
      {:noreply,
       set_open_form(socket, %{
         surface: :inline,
         anchor: %{file_index: i, start_line: f, end_line: t, side: side}
       })}
    else
      :error ->
        log_ignored_event(
          "comment_form.show_at_line",
          "file_index/start_line/end_line",
          {idx, from, to}
        )

        {:noreply, socket}
    end
  end

  def handle_event("comment_form.edit", %{"surface" => surface, "id" => id}, socket) do
    case find_comment(socket.assigns.state, surface, id) do
      nil ->
        {:noreply, socket}

      comment ->
        {:noreply,
         set_open_form(socket, %{
           surface: surface_atom(surface),
           edit_id: id,
           initial_body: comment.body,
           # finding_type is atom for comments added this session, string
           # for ones loaded from on-disk persistence (Jason decodes atom
           # values as strings). to_string/1 handles both.
           initial_finding_type: to_string(comment.finding_type),
           initial_learn_from_this: comment.learn_from_this,
           anchor: anchor_for(surface_atom(surface), comment)
         })}
    end
  end

  def handle_event("comment_form.hide", _, socket) do
    {:noreply, set_open_form(socket, nil)}
  end

  ## --- Submit (add / edit) ---

  def handle_event("comment.submit", _payload, %{assigns: %{open_form: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("comment.submit", payload, socket) do
    %{open_form: form, state: _state, review_id: rid} = socket.assigns
    %{"body" => body, "finding_type" => ft, "learn_from_this" => learn?} = payload

    finding = finding_atom!(ft)

    cond do
      rid == "unbound" ->
        {:noreply, assign(socket, open_form: nil)}

      Map.get(form, :edit_id) ->
        # Edit = remove old + add new (no `edit_comment` server call).
        _ = ReviewServer.remove_comment(rid, form.surface, form.edit_id)
        commit_add(rid, form, body, finding, learn?)
        {:noreply, set_open_form(socket, nil)}

      true ->
        commit_add(rid, form, body, finding, learn?)
        {:noreply, set_open_form(socket, nil)}
    end
  end

  ## --- Remove ---

  def handle_event("comment.remove", %{"surface" => surface, "id" => id}, socket) do
    rid = socket.assigns.review_id

    if rid != "unbound" do
      _ = ReviewServer.remove_comment(rid, surface_atom(surface), id)
    end

    {:noreply, socket}
  end

  ## --- Toggle learn-from-this on a rendered comment ---

  def handle_event(
        "comment.toggle_learn",
        %{"surface" => surface, "id" => id, "learn" => learn},
        socket
      ) do
    rid = socket.assigns.review_id

    if rid != "unbound" do
      learn? = learn in [true, "true", "on"]
      _ = ReviewServer.set_learn_from_this(rid, surface_atom(surface), id, learn?)
    end

    {:noreply, socket}
  end

  ## --- File filter ---

  def handle_event("toolbar.toggle_files_panel", _, socket) do
    {:noreply, assign(socket, files_panel_open: not socket.assigns.files_panel_open)}
  end

  # Toggle whether a file's diff body is rendered. Approved files
  # default-collapse (`expanded_approved` tracks the exceptions);
  # unapproved files default-expand (`collapsed_unapproved` tracks
  # the exceptions). The caret XORs with the default in either
  # direction so the user can collapse anything they're done with,
  # not just approved files.
  def handle_event("file.toggle_expanded", %{"file_name" => file_name}, socket) do
    %{state: state, expanded_approved: expanded, collapsed_unapproved: collapsed} =
      socket.assigns

    approved? = MapSet.member?(state.approved_file_names, file_name)

    socket =
      if approved? do
        assign(socket, expanded_approved: toggle_member(expanded, file_name))
      else
        assign(socket, collapsed_unapproved: toggle_member(collapsed, file_name))
      end

    {:noreply, socket}
  end

  def handle_event("filter.toggle_extension", %{"ext" => ext}, socket) do
    %{state: state, review_id: rid} = socket.assigns
    hidden? = MapSet.member?(state.hidden_extensions, ext)

    if rid != "unbound" do
      _ = ReviewServer.set_extension_hidden(rid, ext, not hidden?)
    end

    {:noreply, socket}
  end

  # `phx-change` form payload always carries the named input via
  # `value` (debounced + batched). Anything else means a malformed
  # client event — fall through to empty string.
  def handle_event("filter.set_input", payload, socket) do
    value = if is_map(payload), do: Map.get(payload, "value", ""), else: ""
    {:noreply, assign(socket, filter_input: value)}
  end

  def handle_event("filter.show_only", %{"file_index" => idx}, socket) do
    case parse_int(idx) do
      {:ok, n} ->
        {:noreply, assign(socket, only_file_index: n)}

      :error ->
        log_ignored_event("filter.show_only", "file_index", idx)
        {:noreply, socket}
    end
  end

  def handle_event("filter.show_all", _, socket) do
    %{state: state, review_id: rid} = socket.assigns

    if rid != "unbound" do
      _ = ReviewServer.set_file_overrides(rid, %{})
    end

    {:noreply, assign(socket, state: %{state | file_overrides: %{}}, only_file_index: nil)}
  end

  def handle_event("filter.toggle_file", %{"file_name" => file_name}, socket) do
    %{
      state: state,
      review_id: rid,
      filter_input: filter_input,
      only_file_index: only_file_index
    } = socket.assigns

    visible = visible_indices(state, filter_input, only_file_index)
    idx = Enum.find_index(state.files, &(&1.file_name == file_name))

    cond do
      idx == nil ->
        {:noreply, socket}

      MapSet.member?(visible, idx) ->
        # Currently visible — checkbox click means HIDE. Override
        # wins over every default filter so the click takes effect
        # immediately and survives a BEAM restart.
        if rid != "unbound", do: _ = ReviewServer.set_file_override(rid, file_name, :hide)
        {:noreply, socket}

      true ->
        # Currently hidden — checkbox click means SHOW. Force-show
        # wins over hidden_extensions / show_generated / any other
        # default filter; pre-existing extension filter stays in
        # place for OTHER files of the same type.
        if rid != "unbound", do: _ = ReviewServer.set_file_override(rid, file_name, :show)
        {:noreply, socket}
    end
  end

  # Bulk hide / show — operate on the files currently passing the
  # substring filter. If every filtered file is currently visible,
  # hide them all; otherwise show them all.
  def handle_event("filter.hide_matched", _, socket) do
    %{state: state, review_id: rid, filter_input: input} = socket.assigns
    matched = matched_file_names(state, input)

    if rid != "unbound" do
      new_overrides =
        Enum.reduce(matched, state.file_overrides, &Map.put(&2, &1, :hide))

      _ = ReviewServer.set_file_overrides(rid, new_overrides)
    end

    {:noreply, socket}
  end

  def handle_event("filter.show_matched", _, socket) do
    %{state: state, review_id: rid, filter_input: input} = socket.assigns
    matched = matched_file_names(state, input)

    if rid != "unbound" do
      new_overrides =
        Enum.reduce(matched, state.file_overrides, &Map.put(&2, &1, :show))

      _ = ReviewServer.set_file_overrides(rid, new_overrides)
    end

    {:noreply, socket}
  end

  def handle_event("hint.dismiss", _, socket) do
    {:noreply, push_event(socket, "hint:set-dismissed", %{})}
  end

  def handle_event("filter.toggle_generated", _, socket) do
    %{review_id: rid, state: state} = socket.assigns

    if rid != "unbound" do
      _ = ReviewServer.set_show_generated(rid, not state.show_generated)
    end

    {:noreply, socket}
  end

  ## --- Decision ---

  def handle_event("decision.approve", _, socket) do
    %{state: state, repo_path: repo_path} = socket.assigns

    # Mirror every staged file's current blob OID into the per-branch
    # approval cache so the next staged-mode hook run on this branch
    # auto-collapses approved files instead of forcing the reviewer to
    # re-tick everything. Run BEFORE `Decision.submit/1` because the
    # CLI's `await` returns immediately after that call and the BEAM
    # exits ~750ms later — a slow bulk write could be cut short.
    bulk_persist_approval_cache(repo_path, state)

    if comments?(state) do
      payload = Feedback.format(state, repo_path, :approval_with_feedback)
      Decision.submit({:approve_with_feedback, payload})
    else
      Decision.submit({:approve, ""})
    end

    clear_pending_answers()

    {:noreply,
     socket
     |> assign(done: :approve, pending_answers: nil)
     |> wipe_drafts()}
  end

  def handle_event("decision.reject", _, socket) do
    %{state: state, repo_path: repo_path} = socket.assigns
    payload = Feedback.format(state, repo_path, :rejection)
    Decision.submit({:reject, payload})
    clear_pending_answers()

    {:noreply,
     socket
     |> assign(done: :reject, pending_answers: nil)
     |> wipe_drafts()}
  end

  def handle_event("decision.post_to_github", _, socket) do
    %{state: state, repo_path: repo_path} = socket.assigns

    with %{number: pr_number} <- state.pr,
         payload <- github_payload(state),
         {:ok, url} <- GitHub.post_review(repo_path, pr_number, payload) do
      {:noreply, assign(socket, flash_error: nil) |> push_event("open-url", %{url: url})}
    else
      nil ->
        {:noreply,
         assign(socket,
           flash_error: "No PR attached to this review — can't post to GitHub."
         )}

      {:error, reason} ->
        IO.puts(:stderr, "meerkat: gh api failed — #{reason}")

        {:noreply,
         assign(socket,
           flash_error: "Couldn't post review to GitHub: #{reason}"
         )}
    end
  end

  def handle_event("flash.dismiss", _, socket) do
    {:noreply, assign(socket, flash_error: nil)}
  end

  def handle_event("decision.cancel", _, socket) do
    rid = socket.assigns.review_id

    # Wipe everything so the empty payload Decision sees has nothing
    # to echo to stderr. The spec asserts the wiped body does NOT
    # appear in stderr after Cancel.
    if rid != "unbound" do
      _ = ReviewServer.clear_all_comments(rid)
    end

    Decision.submit({:cancel, ""})
    clear_pending_answers()

    {:noreply,
     socket
     |> assign(done: :cancel, pending_answers: nil)
     |> wipe_drafts()}
  end

  # Reject an Approve transition if the index blob OID has changed
  # since the UI rendered the file. Un-approve always proceeds —
  # removing a stale tick is harmless. The check uses the
  # server-side file_diff.effective_oid as the source of truth (the
  # value the LV rendered for THIS browser session); we never trust
  # a value the client could tamper with.
  #
  # `effective_oid` values:
  #   nil — range/PR review, no staging concept → skip the check.
  #   ""  — staged mode but the staged-blob lookup failed at
  #          materialise time → block, force a refresh.
  #   OID — the actual blob hash → compare against the live one.
  defp stale_oid_check(_repo_path, _file, false), do: :ok
  defp stale_oid_check(_repo_path, nil, true), do: :ok
  defp stale_oid_check(_repo_path, %{effective_oid: nil}, true), do: :ok

  # Deletion: no blob to content-address against. Empty OID is the
  # expected state and approving a deletion is well-defined ("yes,
  # remove this file"). Pass through; don't block.
  defp stale_oid_check(_repo_path, %{effective_oid: "", status: :deleted}, true), do: :ok

  defp stale_oid_check(_repo_path, %{effective_oid: "", file_name: file_name}, true) do
    {:stale,
     "Couldn't verify #{file_name}'s staged blob OID — refresh the review before approving."}
  end

  defp stale_oid_check(repo_path, %{effective_oid: rendered_oid, file_name: file_name}, true) do
    case Meerkat.Git.fetch_staged_blob_oid(repo_path, file_name) do
      {:ok, ^rendered_oid} ->
        :ok

      :not_staged ->
        {:stale,
         "#{file_name} is no longer staged — refresh the review (or stage it again) before approving."}

      {:error, reason} ->
        {:stale,
         "Couldn't verify #{file_name}'s staged blob OID (#{reason}). " <>
           "Resolve the git issue and refresh before approving."}

      {:ok, _other} ->
        {:stale,
         "#{file_name} changed since you opened the review — refresh to see the new content before approving."}
    end
  end

  defp persist_approval_cache_toggle(repo_path, file_name, approved?, branch, state) do
    with path when is_binary(path) <- ApprovalCache.path_for(repo_path),
         branch when is_binary(branch) <- branch do
      if approved? and missing_effective_oid?(state, file_name) do
        # Can't content-address the approval — log so a non-persisted
        # tick isn't invisible to the operator.
        IO.puts(
          :stderr,
          "meerkat: approval for #{file_name} not persisted to cache: no effective_oid " <>
            "(staged-blob lookup failed at mount, or file not in state)"
        )

        {:error, :missing_oid}
      else
        ApprovalCache.modify(path, fn cache ->
          if approved? do
            ApprovalCache.approve(cache, branch, file_name, effective_oid_for(state, file_name))
          else
            ApprovalCache.unapprove(cache, branch, file_name)
          end
        end)
      end
    else
      _ -> :ok
    end
  end

  defp missing_effective_oid?(state, file_name) do
    case effective_oid_for(state, file_name) do
      oid when is_binary(oid) and oid != "" -> false
      _ -> true
    end
  end

  # Pull effective_oid out of the already-materialised file_diff. Avoids
  # re-shelling out to `git ls-files -s` per toggle — that OID was
  # computed at mount and lives on the file struct.
  defp effective_oid_for(%ReviewState{files: files}, file_name) do
    Enum.find_value(files, fn
      %{file_name: ^file_name, effective_oid: oid} -> oid
      _ -> nil
    end)
  end

  # Approve writes EVERY currently-staged (file_name, oid) into the
  # cache — not just the explicitly-ticked ones — so the next staged-
  # mode hook on this branch can short-circuit the diff for any file
  # whose content didn't change between approve and re-run.
  defp bulk_persist_approval_cache(_repo_path, %ReviewState{head_branch: branch})
       when not is_binary(branch),
       do: :ok

  defp bulk_persist_approval_cache(repo_path, %ReviewState{head_branch: branch, files: files}) do
    case ApprovalCache.path_for(repo_path) do
      nil ->
        :ok

      path ->
        ApprovalCache.modify(path, fn cache ->
          # `effective_oid` is already on every file_diff (populated by
          # materialise_staged at mount). No need to re-shell out to
          # `git ls-files -s` per file inside the cache lockdir.
          Enum.reduce(files, cache, fn %{file_name: name, effective_oid: oid}, c ->
            if is_binary(oid) and oid != "",
              do: ApprovalCache.approve(c, branch, name, oid),
              else: c
          end)
        end)

        :ok
    end
  end

  defp clear_pending_answers do
    repo_path = Application.get_env(:meerkat, :repo_path) || File.cwd!()
    PendingAnswers.clear(repo_path)
  end

  ## --- PubSub ---

  @impl true
  def handle_info({:state_changed, %ReviewState{} = state}, socket) do
    {:noreply, assign(socket, state: state, open_form: Map.get(state, :open_form, nil))}
  end

  def handle_info({:persistence_failed, reason}, socket) do
    msg =
      "Comments aren't being saved to disk (#{inspect(reason)}). " <>
        "Copy any in-progress text before closing the tab; resolve the underlying issue and re-tick."

    {:noreply, assign(socket, flash_error: msg)}
  end

  ## --- Render ---

  @impl true
  def render(%{done: done} = assigns) when done != nil do
    ~H"""
    <main class="review done">
      <h1>{done_heading(@done)}</h1>
      <p>You can close this tab.</p>
      <div id="window-close-host" phx-hook="WindowClose"></div>
    </main>
    """
  end

  def render(assigns) do
    # Backfill assigns added since this socket mounted — needed for
    # the DevWatcher hot-reload path where a previously-mounted LV
    # keeps its socket but new code expects new assigns.
    assigns =
      assigns
      |> assign_new(:plantuml_available, fn -> Meerkat.PlantUML.available?() end)
      |> assign_new(:expanded_approved, fn -> MapSet.new() end)
      |> assign_new(:collapsed_unapproved, fn -> MapSet.new() end)
      # Compute once per render and thread into both children.
      # `visible_indices/3` does a full scan of state.files with cond
      # branching per file — at twice per render it was the hot spot
      # on every PubSub broadcast.
      |> assign(
        :visible_indices,
        visible_indices(assigns.state, assigns.filter_input, assigns.only_file_index)
      )
      # Pre-group comments by file_index so file_list doesn't filter +
      # sort the full list F times (O(F×C) → O(F+C) per render).
      # Pre-render markdown into :body_html so the template doesn't
      # re-parse on every PubSub-driven render.
      |> assign(:inline_comments_by_file, group_inline_by_file(assigns.state.comments))
      |> assign(:file_comments_by_file, group_file_by_file_with_html(assigns.state.file_comments))
      |> assign(
        :global_comments_rendered,
        Enum.map(assigns.state.global_comments, &with_body_html/1)
      )
      |> assign(
        :commit_message_comments_rendered,
        Enum.map(assigns.state.commit_message_comments, &with_body_html/1)
      )

    ~H"""
    <main class="review" id="meerkat-root" phx-hook="Settings">
      <.diff_toolbar
        mode={@diff_mode}
        wrap_lines={@wrap_lines}
        font_size_px={@font_size_px}
        tab_size={@tab_size}
        state={@state}
        repo_path={@repo_path}
        open_form={@open_form}
      />
      <.flash_error_banner :if={@flash_error} message={@flash_error} />
      <.pending_answers_banner :if={@pending_answers} pending_answers={@pending_answers} />
      <.commit_message_section
        :if={@state.commit_message != ""}
        state={@state}
        rendered_comments={@commit_message_comments_rendered}
        open_form={@open_form}
        socket={@socket}
        review_id={@review_id}
      />
      <.global_comments_section
        state={@state}
        rendered_comments={@global_comments_rendered}
        open_form={@open_form}
        socket={@socket}
        review_id={@review_id}
      />
      <p :if={@state.files != []} class="hint" phx-hook="HintDismiss" id="meerkat-hint">
        Tip: click a line number to comment on that line — click and drag for a range. {if @state.commit_message !=
                                                                                             "",
                                                                                           do:
                                                                                             "The commit-message gutter at the top works the same way.",
                                                                                           else: ""}
        <button
          type="button"
          class="hint-dismiss"
          phx-click="hint.dismiss"
          aria-label="Dismiss hint"
          title="Dismiss"
        >
          ×
        </button>
      </p>
      <.file_filter
        :if={@files_panel_open}
        state={@state}
        filter_input={@filter_input}
        only_file_index={@only_file_index}
        visible_indices={@visible_indices}
      />
      <div class="review-body">
        <.file_list
          state={@state}
          socket={@socket}
          mode={@diff_mode}
          wrap_lines={@wrap_lines}
          font_size_px={@font_size_px}
          tab_size={@tab_size}
          open_form={@open_form}
          visible_indices={@visible_indices}
          expanded_approved={@expanded_approved}
          collapsed_unapproved={@collapsed_unapproved}
          inline_comments_by_file={@inline_comments_by_file}
          file_comments_by_file={@file_comments_by_file}
          plantuml_available={@plantuml_available}
          review_id={@review_id}
        />
      </div>
      <.decision_footer state={@state} open_form={@open_form} />
    </main>
    """
  end

  ## --- Components ---

  # Inline "learn?" toggle rendered next to each comment's Edit /
  # Remove buttons. Lets reviewers flip the learn-from-this flag
  # without re-opening the form. `learn` value is sent as "true" or
  # "false" so the LV handler can coerce.
  attr :surface, :string, required: true
  attr :comment, :map, required: true

  defp learn_toggle(assigns) do
    ~H"""
    <label
      class="learn-toggle"
      title="Include this comment in the agent's learning corpus"
    >
      <input
        type="checkbox"
        checked={!!@comment.learn_from_this}
        phx-click="comment.toggle_learn"
        phx-value-surface={@surface}
        phx-value-id={@comment.id}
        phx-value-learn={if @comment.learn_from_this, do: "false", else: "true"}
      />
      <span>learn from this</span>
    </label>
    """
  end

  attr :message, :string, required: true

  defp flash_error_banner(assigns) do
    ~H"""
    <section class="flash-error" role="alert" data-test="flash-error">
      <p>{@message}</p>
      <button type="button" phx-click="flash.dismiss" aria-label="Dismiss">×</button>
    </section>
    """
  end

  attr :pending_answers, :any, required: true

  defp pending_answers_banner(assigns) do
    ~H"""
    <section class="pending-answers">
      <h2>Pending answers ({length(@pending_answers.answers)})</h2>
      <ul>
        <li :for={a <- @pending_answers.answers} class="pending-answer">
          <div class="location">{a.location}</div>
          <div class="question markdown">
            <span class="answer-prefix">Q:</span>
            {Phoenix.HTML.raw(Meerkat.Markdown.to_safe_html(a.question))}
          </div>
          <div class="answer markdown">
            <span class="answer-prefix">A:</span>
            {Phoenix.HTML.raw(Meerkat.Markdown.to_safe_html(a.answer))}
          </div>
        </li>
      </ul>
    </section>
    """
  end

  # Connection status pill — the Phoenix LV client toggles
  # `.phx-loading`, `.phx-error`, `.phx-server-error`,
  # `.phx-client-error` on a wrapper above the LV. CSS targets
  # those ancestor classes to flip the dot colour + label without
  # any LV-side JS hook.
  defp connection_indicator(assigns) do
    ~H"""
    <span class="conn-indicator" title="Connection to meerkat server" aria-live="polite">
      <span class="conn-dot" aria-hidden="true"></span>
      <span class="conn-label-connected">connected</span>
      <span class="conn-label-loading">connecting…</span>
      <span class="conn-label-error">disconnected</span>
    </span>
    """
  end

  attr :state, ReviewState, required: true
  attr :rendered_comments, :any, required: true
  attr :open_form, :any, required: true
  attr :socket, :any, required: true
  attr :review_id, :string, required: true

  defp commit_message_section(assigns) do
    ~H"""
    <section
      class="commit-message-section"
      aria-label="Commit message — click the gutter to comment"
    >
      <ol class="commit-msg-gutter" id="commit-msg-gutter" phx-hook="CommitMsgGutter">
        <li
          :for={block <- @state.commit_message_blocks}
          data-start-line={block.start_line}
          data-end-line={block.end_line}
        >
          <button
            type="button"
            class="gutter-line-num"
            aria-label={gutter_label(block)}
            phx-click="comment_form.show_commit_msg"
            phx-value-start_line={block.start_line}
            phx-value-end_line={block.end_line}
          >
            {block.start_line}
          </button>
          <div class="gutter-text markdown">
            {Phoenix.HTML.raw(Meerkat.Markdown.to_safe_html(block.text))}
          </div>
        </li>
      </ol>
      <ul class="commit-msg-comments">
        <li :for={comment <- @rendered_comments} class="note commit-msg-note">
          <header>
            <span class="finding-badge">{finding_label(comment.finding_type)}</span>
            <span class="line-anchor">L{comment.start_line}–{comment.end_line}</span>
            <.learn_toggle surface="commit_msg" comment={comment} />
            <button
              type="button"
              phx-click="comment_form.edit"
              phx-value-surface="commit_msg"
              phx-value-id={comment.id}
            >
              Edit
            </button>
            <button
              type="button"
              phx-click="comment.remove"
              phx-value-surface="commit_msg"
              phx-value-id={comment.id}
            >
              Remove
            </button>
          </header>
          <div class="comment-body">
            {Phoenix.HTML.raw(comment.body_html)}
          </div>
        </li>
      </ul>
      <.svelte
        :if={form_for(@open_form, :commit_msg)}
        id="CommentForm-commit-msg"
        name="CommentForm"
        props={commit_msg_form_props(@open_form, @review_id, @state.commit_message)}
        socket={@socket}
      />
    </section>
    """
  end

  attr :state, ReviewState, required: true
  attr :rendered_comments, :any, required: true
  attr :open_form, :any, required: true
  attr :socket, :any, required: true
  attr :review_id, :string, required: true

  defp global_comments_section(assigns) do
    ~H"""
    <section
      :if={@rendered_comments != [] or form_for(@open_form, :global)}
      class="global-comments"
      aria-label="Global comments"
    >
      <ul>
        <li :for={comment <- @rendered_comments} class={"note note-#{comment.finding_type}"}>
          <header>
            <span class="finding-badge">{finding_label(comment.finding_type)}</span>
            <.learn_toggle surface="global" comment={comment} />
            <button
              type="button"
              phx-click="comment_form.edit"
              phx-value-surface="global"
              phx-value-id={comment.id}
            >
              Edit
            </button>
            <button
              type="button"
              phx-click="comment.remove"
              phx-value-surface="global"
              phx-value-id={comment.id}
            >
              Remove
            </button>
          </header>
          <div class="comment-body">
            {Phoenix.HTML.raw(comment.body_html)}
          </div>
        </li>
      </ul>
      <button
        :if={@state.global_comments != [] and not form_for(@open_form, :global)}
        type="button"
        class="ghost-btn small"
        phx-click="comment_form.show_global"
      >
        + Add another
      </button>
      <.svelte
        :if={form_for(@open_form, :global)}
        id="CommentForm-global"
        name="CommentForm"
        props={global_form_props(@open_form, @review_id)}
        socket={@socket}
      />
    </section>
    <button
      :if={@state.global_comments == [] and not form_for(@open_form, :global)}
      type="button"
      class="ghost-btn add-global-btn"
      phx-click="comment_form.show_global"
    >
      + Add global comment
    </button>
    """
  end

  attr :state, ReviewState, required: true
  attr :socket, :any, required: true
  attr :mode, :string, required: true
  attr :wrap_lines, :boolean, required: true
  attr :font_size_px, :integer, required: true
  attr :tab_size, :integer, required: true
  attr :open_form, :any, required: true
  attr :visible_indices, :any, required: true
  attr :expanded_approved, :any, required: true
  attr :collapsed_unapproved, :any, required: true
  attr :inline_comments_by_file, :any, required: true
  attr :file_comments_by_file, :any, required: true
  attr :plantuml_available, :boolean, required: true
  attr :review_id, :string, required: true

  defp file_list(assigns) do
    ~H"""
    <section class="file-list">
      <article
        :for={{file, idx} <- Enum.with_index(@state.files)}
        :if={MapSet.member?(@visible_indices, idx)}
        id={"file-#{idx}"}
        class={[
          "file-section",
          MapSet.member?(@state.approved_file_names, file.file_name) && "approved",
          file_section_collapsed?(@state, @expanded_approved, @collapsed_unapproved, file.file_name) &&
            "collapsed"
        ]}
      >
        <header class="file-section-header">
          <button
            type="button"
            class={"file-row file-row-#{file.status}"}
            phx-click="file.toggle_expanded"
            phx-value-file_name={file.file_name}
          >
            <span class={[
              "caret",
              file_section_collapsed?(
                @state,
                @expanded_approved,
                @collapsed_unapproved,
                file.file_name
              ) && "collapsed"
            ]}>
              ▾
            </span>
            <span class={"status-badge status-#{file.status}"}>{status_badge(file.status)}</span>
            <span class="file-name">{file.file_name}</span>
            <%= if file.old_file_name do %>
              <span class="rename-from">(was {file.old_file_name})</span>
            <% end %>
          </button>
          <button
            type="button"
            class="file-action copy-name"
            phx-hook="CopyOnClick"
            id={"copy-name-#{idx}"}
            data-copy={file.file_name}
            title="Copy file name"
            aria-label="Copy file name"
          >
            <span aria-hidden="true">⧉</span>
          </button>
          <a
            :if={file.status != :deleted}
            class="file-action view-file"
            href={"/api/file?review_id=#{@review_id}&file_index=#{idx}&side=new"}
            target="_blank"
            rel="noopener"
            title="Open full file content in a new tab"
            aria-label="Open full file"
          >
            <span aria-hidden="true">↗</span>
          </a>
          <label class="approved-toggle">
            <input
              type="checkbox"
              phx-click="file.toggle_approved"
              phx-value-file_name={file.file_name}
              checked={MapSet.member?(@state.approved_file_names, file.file_name)}
            />
            <span>Approved</span>
          </label>
        </header>
        <.svelte
          :if={
            not file_section_collapsed?(
              @state,
              @expanded_approved,
              @collapsed_unapproved,
              file.file_name
            )
          }
          id={"DiffViewer-#{idx}"}
          name="DiffViewer"
          props={
            %{
              file: file,
              file_index: idx,
              mode: @mode,
              wrap_lines: @wrap_lines,
              font_size_px: @font_size_px,
              tab_size: @tab_size,
              comments: Map.get(@inline_comments_by_file, idx, []),
              inline_form: inline_form_for_diff(@open_form, idx, @state, @review_id),
              plantuml_available: @plantuml_available
            }
          }
          socket={@socket}
        />
        <ul
          :if={
            not file_section_collapsed?(
              @state,
              @expanded_approved,
              @collapsed_unapproved,
              file.file_name
            )
          }
          class="file-comments"
        >
          <li
            :for={comment <- Map.get(@file_comments_by_file, idx, [])}
            class={"note note-#{comment.finding_type} file-note"}
          >
            <header>
              <span class="finding-badge">{finding_label(comment.finding_type)}</span>
              <.learn_toggle surface="file" comment={comment} />
              <button
                type="button"
                phx-click="comment_form.edit"
                phx-value-surface="file"
                phx-value-id={comment.id}
              >
                Edit
              </button>
              <button
                type="button"
                phx-click="comment.remove"
                phx-value-surface="file"
                phx-value-id={comment.id}
              >
                Remove
              </button>
            </header>
            <div class="comment-body">
              {Phoenix.HTML.raw(comment.body_html)}
            </div>
          </li>
        </ul>
        <button
          :if={
            not file_section_collapsed?(
              @state,
              @expanded_approved,
              @collapsed_unapproved,
              file.file_name
            ) and
              not file_form_open_for?(@open_form, idx)
          }
          type="button"
          phx-click="comment_form.show_file"
          phx-value-file_index={idx}
        >
          + Add file comment
        </button>
        <.svelte
          :if={
            not file_section_collapsed?(
              @state,
              @expanded_approved,
              @collapsed_unapproved,
              file.file_name
            ) and
              file_form_open_for?(@open_form, idx)
          }
          id={"CommentForm-file-#{idx}"}
          name="CommentForm"
          props={file_form_props(@open_form, idx, @state, @review_id)}
          socket={@socket}
        />
      </article>
    </section>
    """
  end

  attr :state, ReviewState, required: true
  attr :filter_input, :string, required: true
  attr :only_file_index, :any, required: true
  attr :visible_indices, :any, required: true

  defp file_filter(assigns) do
    # Sidebar that lists every file with hover-revealed "hide *.ext"
    # and "only" buttons, plus a `.filter-input` for substring narrowing.
    # The list filters by `filter_input` (substring on base_name); the
    # actual diff body in `.file-list` further filters by hidden
    # extensions + `only_file_index`.
    visible_in_sidebar =
      filter_sidebar_entries(assigns.state.files, assigns.filter_input)

    matched_visible? =
      Enum.all?(visible_in_sidebar, fn {_f, idx} ->
        MapSet.member?(assigns.visible_indices, idx)
      end)

    assigns =
      assign(assigns,
        sidebar_entries: visible_in_sidebar,
        total_count: length(assigns.state.files),
        visible_count: length(visible_in_sidebar),
        matched_visible?: matched_visible?
      )

    ~H"""
    <aside class="file-filter">
      <header class="file-filter-header">
        <button
          type="button"
          class="file-filter-toggle"
          phx-click="toolbar.toggle_files_panel"
          title="Close file panel"
        >
          Files ({@visible_count} of {@total_count})
        </button>
        <button
          type="button"
          class="ghost-btn small"
          phx-click={if @matched_visible?, do: "filter.hide_matched", else: "filter.show_matched"}
        >
          {if @matched_visible?, do: "Hide matched", else: "Show matched"}
        </button>
        <button
          :if={@only_file_index != nil or map_size(@state.file_overrides) > 0}
          type="button"
          class="ghost-btn small"
          phx-click="filter.show_all"
        >
          Show all
        </button>
      </header>

      <form phx-change="filter.set_input">
        <input
          type="text"
          name="value"
          class="filter-input"
          placeholder="Filter files…"
          value={@filter_input}
          phx-debounce="50"
        />
      </form>

      <ul class="hidden-extensions">
        <li :if={any_generated?(@state.files)}>
          <button
            type="button"
            class={["filter-chip", @state.show_generated && "active"]}
            phx-click="filter.toggle_generated"
            title={
              if @state.show_generated,
                do: "Hide linguist-generated files",
                else: "Show linguist-generated files"
            }
          >
            generated {if @state.show_generated, do: "✓", else: "×"}
          </button>
        </li>
        <li :for={ext <- MapSet.to_list(@state.hidden_extensions)}>
          <button
            type="button"
            class="filter-chip"
            phx-click="filter.toggle_extension"
            phx-value-ext={ext}
            title={"Show .#{ext} again"}
          >
            .{ext} ×
          </button>
        </li>
      </ul>

      <ul class="file-entries">
        <li
          :for={{file, idx} <- @sidebar_entries}
          class={[
            "file-entry",
            not MapSet.member?(@visible_indices, idx) && "hidden-by-other"
          ]}
        >
          <input
            type="checkbox"
            phx-click="filter.toggle_file"
            phx-value-file_name={file.file_name}
            checked={MapSet.member?(@visible_indices, idx)}
            title={"Show / hide #{file.file_name} in the diff list"}
          />
          <span class={"status-dot status-#{file.status}"} title={status_label(file.status)}></span>
          <a class="file-path" href={"#file-#{idx}"} title={file.file_name}>
            <span class="dir">{file_path_dir(file.file_name)}</span><span class="base-name">{Path.basename(file.file_name)}</span>
          </a>
          <button
            type="button"
            class="ghost-btn small only-btn"
            phx-click="filter.show_only"
            phx-value-file_index={idx}
            title="Show only this file"
          >
            only
          </button>
          <button
            :if={extension_of(file.file_name) != ""}
            type="button"
            class="ghost-btn small hide-ext-btn"
            phx-click="filter.toggle_extension"
            phx-value-ext={extension_of(file.file_name)}
            title={"Hide every *.#{extension_of(file.file_name)} file"}
          >
            hide *.{extension_of(file.file_name)}
          </button>
        </li>
      </ul>
    </aside>
    """
  end

  attr :mode, :string, required: true
  attr :wrap_lines, :boolean, required: true
  attr :font_size_px, :integer, required: true
  attr :tab_size, :integer, required: true
  attr :state, ReviewState, required: true
  attr :repo_path, :string, required: true
  attr :open_form, :any, required: true

  defp diff_toolbar(assigns) do
    ~H"""
    <div class="diff-toolbar">
      <button
        type="button"
        class="toolbar-icon-btn"
        phx-click="toolbar.toggle_files_panel"
        title="Toggle file list / filter sidebar"
        aria-label="Toggle file list"
      >
        ☰ Files
      </button>

      <a
        :if={@state.pr}
        class="chip chip-link"
        href={@state.pr.url}
        target="_blank"
        rel="noopener"
        title={"#{@state.pr.title} — open on GitHub"}
      >
        <span class="chip-label">PR</span>
        <code class="chip-value">#{@state.pr.number}</code>
      </a>

      <div class="toolbar-title" title={toolbar_title(@state)}>
        {toolbar_title(@state)}
      </div>

      <span
        :if={@state.base_branch && @state.head_branch}
        class="chip branch-chip"
        title={@repo_path}
      >
        <code class="chip-value">{@state.base_branch}</code>
        <span class="chip-arrow">←</span>
        <code class="chip-value">{@state.head_branch}</code>
      </span>

      <span
        :if={!(@state.base_branch && @state.head_branch) && @state.head_branch}
        class="chip branch-chip"
        title={@repo_path}
      >
        <code class="chip-value">{@state.head_branch}</code>
      </span>

      <.connection_indicator />

      <div class="toolbar-group">
        <button
          type="button"
          phx-click="set_diff_mode"
          phx-value-mode="split"
          class={if @mode == "split", do: "active", else: ""}
        >
          Split
        </button>
        <button
          type="button"
          phx-click="set_diff_mode"
          phx-value-mode="unified"
          class={if @mode == "unified", do: "active", else: ""}
        >
          Unified
        </button>
      </div>

      <label class="toolbar-group wrap-toggle">
        <input
          type="checkbox"
          phx-click="toolbar.toggle_wrap"
          checked={@wrap_lines}
        />
        <span>Wrap</span>
      </label>

      <details class="toolbar-group toolbar-settings">
        <summary title="Display settings">⚙</summary>
        <div class="toolbar-settings-popover">
          <div class="toolbar-group">
            <span class="toolbar-label">Font</span>
            <button
              type="button"
              phx-click="toolbar.bump_font_size"
              phx-value-by="-1"
              aria-label="Decrease font size"
            >
              −
            </button>
            <span class="toolbar-value">{@font_size_px}px</span>
            <button
              type="button"
              phx-click="toolbar.bump_font_size"
              phx-value-by="1"
              aria-label="Increase font size"
            >
              +
            </button>
          </div>

          <div class="toolbar-group">
            <span class="toolbar-label">Tab</span>
            <button
              :for={n <- [2, 4, 8]}
              type="button"
              phx-click="toolbar.set_tab_size"
              phx-value-n={n}
              class={if @tab_size == n, do: "active", else: ""}
            >
              {n}
            </button>
          </div>
        </div>
      </details>
    </div>
    """
  end

  # The big middle slot of the floating toolbar: PR title when one is
  # attached, otherwise the commit-message subject (first non-empty
  # line), otherwise the head-branch name. Empty string when nothing
  # interesting is known — the chip just shrinks to zero width.
  defp toolbar_title(%ReviewState{pr: %{title: t}}) when is_binary(t) and t != "", do: t

  defp toolbar_title(%ReviewState{commit_message: msg}) when is_binary(msg) and msg != "" do
    msg |> String.split("\n", parts: 2) |> List.first() |> String.trim()
  end

  defp toolbar_title(%ReviewState{head_branch: b}) when is_binary(b) and b != "", do: b
  defp toolbar_title(_), do: ""

  attr :state, ReviewState, required: true
  attr :open_form, :any, required: true

  defp decision_footer(assigns) do
    assigns =
      assign(assigns,
        comments?: comments?(assigns.state),
        comment_count: comment_count(assigns.state),
        dirty?: assigns.open_form != nil
      )

    ~H"""
    <footer class="decision-footer">
      <div class="decision-meta">
        <span class="comment-count">
          {@comment_count} {if @comment_count == 1, do: "comment", else: "comments"}
        </span>
        <%= if @dirty? do %>
          <span class="dirty-marker" title="Close the open comment form first">
            unsaved form open
          </span>
        <% end %>
      </div>
      <div class="decision-actions">
        <button
          type="button"
          class="ghost-btn cancel-btn"
          phx-click="decision.cancel"
        >
          Cancel
        </button>
        <button
          :if={@state.pr && not @state.precommit?}
          type="button"
          class="ghost-btn"
          phx-click="decision.post_to_github"
          disabled={@dirty?}
          title={
            if @dirty?,
              do: "Submit or discard the open comment first",
              else: "Post these comments to the PR as a GitHub pending review"
          }
        >
          Post to GitHub
        </button>
        <button
          type="button"
          class="warn-btn reject-btn"
          phx-click="decision.reject"
          disabled={@dirty? or not @comments?}
        >
          Send Feedback
        </button>
        <button
          type="button"
          class="primary-btn approve-btn"
          phx-click="decision.approve"
          disabled={@dirty?}
        >
          {if @comments?, do: "Approve with feedback", else: "Approve"}
        </button>
      </div>
    </footer>
    """
  end

  defp comment_count(state) do
    length(state.comments) + length(state.file_comments) +
      length(state.global_comments) + length(state.commit_message_comments)
  end

  ## --- Helpers ---

  # File extension WITHOUT the leading dot (e.g. "md", "rs"). Empty
  # string for extensionless files; callers don't render a hide-type
  # button in that case.
  defp extension_of(file_name) do
    file_name
    |> Path.extname()
    |> String.trim_leading(".")
  end

  # True if any file in the diff is linguist-generated. Drives whether
  # the file-filter panel shows the "generated ×" chip — no point
  # rendering it when there's nothing to toggle.
  defp any_generated?(files), do: Enum.any?(files, &Map.get(&1, :is_generated, false))

  # Filter the sidebar's `fileEntries` list by the `filter_input`
  # substring on the base name. Returns `[{file, idx}, …]` so the
  # template doesn't lose the index needed for `filter.show_only`.
  defp filter_sidebar_entries(files, ""), do: Enum.with_index(files)

  defp filter_sidebar_entries(files, input) do
    needle = String.downcase(input)

    files
    |> Enum.with_index()
    |> Enum.filter(fn {file, _idx} ->
      file.file_name |> Path.basename() |> String.downcase() |> String.contains?(needle)
    end)
  end

  # Files matching the current substring filter — the set the bulk
  # Hide/Show buttons operate on. Empty input → every file.
  defp matched_file_names(state, input) do
    needle = String.downcase(input || "")

    state.files
    |> Enum.filter(fn f ->
      needle == "" or
        f.file_name |> Path.basename() |> String.downcase() |> String.contains?(needle)
    end)
    |> Enum.map(& &1.file_name)
  end

  # The set of file indices visible in the main `.file-list` section.
  # Filters compose: linguist-generated (always hidden unless the
  # user toggles "show generated"), hidden_extensions (persisted),
  # only_file_index (ephemeral), filter_input (ephemeral),
  # file_overrides (persisted — per-row file-filter checkbox wins
  # over every default filter).
  defp visible_indices(state, filter_input, only_file_index) do
    show_generated? = state.show_generated

    state.files
    |> Enum.with_index()
    |> Enum.reduce(MapSet.new(), fn {file, idx}, acc ->
      ext = extension_of(file.file_name)

      override = Map.get(state.file_overrides, file.file_name)

      cond do
        override == :show and (only_file_index == nil or only_file_index == idx) and
            (filter_input == "" or matches_filter?(file.file_name, filter_input)) ->
          MapSet.put(acc, idx)

        override == :hide ->
          acc

        not show_generated? and Map.get(file, :is_generated, false) ->
          acc

        MapSet.member?(state.hidden_extensions, ext) ->
          acc

        only_file_index != nil and only_file_index != idx ->
          acc

        filter_input != "" and not matches_filter?(file.file_name, filter_input) ->
          acc

        true ->
          MapSet.put(acc, idx)
      end
    end)
  end

  defp matches_filter?(file_name, input) do
    file_name |> Path.basename() |> String.downcase() |> String.contains?(String.downcase(input))
  end

  defp done_heading(:approve), do: "Approved"
  defp done_heading(:reject), do: "Feedback sent"
  defp done_heading(:cancel), do: "Cancelled"

  defp comments?(state) do
    state.comments != [] or state.file_comments != [] or
      state.global_comments != [] or state.commit_message_comments != []
  end

  # GitHub PENDING review payload. Inline comments map 1:1 to
  # GitHub's per-line review-comment shape (single-line uses `line` +
  # `side`; multi-line uses `start_line` + `line` + `start_side` +
  # `side`). Non-inline comments (global / file / commit-msg) don't
  # have a GitHub native slot, so they fold into the review body,
  # separated with `---` dividers. Same shape as the stderr feedback
  # so external scripts that diff stderr vs PR body stay
  # round-trippable. Inline comments use the new side only (the only
  # side meerkat ever pushes to — old-side comments are rare and the
  # spec doesn't exercise them).
  defp github_payload(state) do
    %{
      event: "PENDING",
      body: build_review_body(state),
      comments: Enum.map(state.comments, &github_inline_comment(state, &1))
    }
  end

  defp github_inline_comment(state, c) do
    path = github_path_for(state, c.file_index)
    side = if to_string(c.side) == "old", do: "LEFT", else: "RIGHT"
    labelled = label_for_github(c.finding_type, c.body)

    body =
      if c.learn_from_this do
        labelled <>
          "\n\n_please learn from this: save a memory, update a skill, or " <>
          "tighten the review-agent prompt so this class of issue is caught next time._"
      else
        labelled
      end

    if c.start_line == c.end_line do
      %{path: path, line: c.end_line, side: side, body: body}
    else
      %{
        path: path,
        start_line: c.start_line,
        line: c.end_line,
        start_side: side,
        side: side,
        body: body
      }
    end
  end

  defp build_review_body(state) do
    sections =
      [
        for(gc <- state.global_comments, do: global_section(gc)),
        for(fc <- state.file_comments, do: file_section_md(state, fc)),
        for(cmc <- state.commit_message_comments, do: commit_msg_section_md(cmc))
      ]
      |> List.flatten()
      |> Enum.reject(&(&1 == ""))

    Enum.join(sections, "\n\n---\n\n")
  end

  defp global_section(gc) do
    labelled = label_for_github(gc.finding_type, gc.body)

    if gc.learn_from_this,
      do: labelled <> "\n\n_please learn from this._",
      else: labelled
  end

  defp file_section_md(state, fc) do
    path = github_path_for(state, fc.file_index)
    labelled = label_for_github(fc.finding_type, fc.body)

    if fc.learn_from_this,
      do: "**#{path}**:\n\n" <> labelled <> "\n\n_please learn from this._",
      else: "**#{path}**:\n\n" <> labelled
  end

  defp commit_msg_section_md(cmc) do
    range =
      if cmc.start_line == cmc.end_line,
        do: "#{cmc.start_line}",
        else: "#{cmc.start_line}-#{cmc.end_line}"

    labelled = label_for_github(cmc.finding_type, cmc.body)

    if cmc.learn_from_this,
      do:
        "**commit message (line #{range})**:\n\n" <> labelled <> "\n\n_please learn from this._",
      else: "**commit message (line #{range})**:\n\n" <> labelled
  end

  # Conventional-Comments markdown label. Empty body + revert renders
  # as a stand-alone sentence; other types format as `**type:** body`.
  defp label_for_github(ft, body) do
    ft_str = ft |> to_string() |> String.trim()
    body_trim = (body || "") |> String.trim()

    cond do
      ft_str == "" -> body || ""
      body_trim == "" and ft_str == "revert" -> "**restore from HEAD**"
      true -> "**#{ft_str}:** #{body || ""}"
    end
  end

  @doc false
  # Test seam — exposes `label_for_github/2` so unit tests can pin the
  # GitHub-PR-body wording without driving the full github_payload
  # pipeline.
  def label_for_github_for_test(ft, body), do: label_for_github(ft, body)

  defp github_path_for(state, file_index) do
    case Enum.at(state.files, file_index) do
      %{file_name: name} -> name
      _ -> ""
    end
  end

  defp status_badge(:added), do: "A"
  defp status_badge(:modified), do: "M"
  defp status_badge(:deleted), do: "D"
  defp status_badge(:renamed), do: "R"

  defp status_label(:added), do: "Added"
  defp status_label(:modified), do: "Modified"
  defp status_label(:deleted), do: "Deleted"
  defp status_label(:renamed), do: "Renamed"

  # Directory prefix with a trailing slash, or "" for files in the
  # repo root. Sidebar renders this in muted grey before the bold
  # base name so deep paths show their tree context without
  # consuming a row each.
  defp file_path_dir(file_name) do
    case Path.dirname(file_name) do
      "." -> ""
      "" -> ""
      dir -> "#{dir}/"
    end
  end

  # Approved files collapse by default; the reviewer can override
  # per-file via the header click (which toggles
  # `expanded_approved`). Un-approved files are always expanded.
  # A file is "collapsed" if the user's explicit toggle has put it on
  # the opposite side of its default (approved files default to
  # collapsed, unapproved default to expanded). Either set toggles
  # the SAME file_name — clicking the caret on an approved file
  # writes to `expanded_approved`, on an unapproved file it writes
  # to `collapsed_unapproved`. The XOR keeps the semantics clean
  # even when approval flips while the file is already toggled.
  defp file_section_collapsed?(state, expanded_approved, collapsed_unapproved, file_name) do
    approved? = MapSet.member?(state.approved_file_names, file_name)

    if approved? do
      not MapSet.member?(expanded_approved, file_name)
    else
      MapSet.member?(collapsed_unapproved, file_name)
    end
  end

  defp group_inline_by_file(comments) do
    comments
    |> Enum.group_by(& &1.file_index)
    |> Map.new(fn {idx, list} ->
      sorted = Enum.sort_by(list, fn c -> {c.start_line, c.created_at} end)
      {idx, Enum.map(sorted, &with_body_html/1)}
    end)
  end

  defp group_file_by_file_with_html(file_comments) do
    file_comments
    |> Enum.group_by(& &1.file_index)
    |> Map.new(fn {idx, list} -> {idx, Enum.map(list, &with_body_html/1)} end)
  end

  # Attach a server-rendered `body_html` so the Svelte InlineComment
  # component can render markdown (including suggestion fences) via
  # `@html`. Done here instead of in the Comment struct so the
  # canonical state stays serialisation-only — markdown is a view
  # concern.
  defp with_body_html(%{body: body, finding_type: ft} = comment) do
    Map.put(comment, :body_html, render_comment_body(body, ft))
  end

  # Render any comment body. Empty-body revert gets a synthesised
  # label naming the operation (`git restore --source=HEAD`-style).
  # The comment's own anchor already names the line range, so the
  # label stays subject-less. "revert this change" was being
  # misread as "undo my latest in-session edit" or "go back to
  # some PR-ago state"; HEAD is staged-mode-precise and meerkat
  # only ships staged mode in practice.
  defp render_comment_body(body, finding_type) do
    if to_string(finding_type) == "revert" and String.trim(body || "") == "" do
      "<p><strong>Restore from HEAD.</strong></p>"
    else
      Meerkat.Markdown.to_safe_html(body)
    end
  end

  @doc false
  # Test seam — exposes `render_comment_body/2` so unit tests can pin
  # the synthesised empty-body revert HTML the in-tab Svelte
  # InlineComment renders.
  def render_comment_body_for_test(body, finding_type),
    do: render_comment_body(body, finding_type)

  defp gutter_label(%{start_line: n, end_line: n}),
    do: "Comment on commit message line #{n}"

  defp gutter_label(%{start_line: from, end_line: to}),
    do: "Comment on commit message lines #{from} through #{to}"

  defp form_for(nil, _), do: false
  defp form_for(%{surface: surface}, surface), do: true
  defp form_for(_, _), do: false

  defp file_form_open_for?(nil, _idx), do: false
  defp file_form_open_for?(%{surface: :file, anchor: %{file_index: idx}}, idx), do: true
  defp file_form_open_for?(_, _), do: false

  # Whitelist string → atom. Unknown atoms (from a tampered client
  # payload) raise rather than pass through, so downstream
  # ReviewServer.add_comment/3 / remove_comment/3 never see a
  # surface they can't dispatch on.
  defp surface_atom("global"), do: :global
  defp surface_atom("file"), do: :file
  defp surface_atom("commit_msg"), do: :commit_msg
  defp surface_atom("inline"), do: :inline
  defp surface_atom(s) when s in [:global, :file, :commit_msg, :inline], do: s

  # Whitelist coerce: the client only ever sends one of these five.
  # Any other string crashes the handler, which is the right thing —
  # client-side tampering should not yield a writable atom.
  defp finding_atom!("issue"), do: :issue
  defp finding_atom!("suggestion"), do: :suggestion
  defp finding_atom!("question"), do: :question
  defp finding_atom!("follow-up"), do: :follow_up
  defp finding_atom!("follow_up"), do: :follow_up
  # Back-compat: existing in-progress drafts persisted under the old
  # `thought` label still round-trip into the new `:follow_up` atom.
  defp finding_atom!("thought"), do: :follow_up
  defp finding_atom!("revert"), do: :revert

  # Human-readable badge label. Keep finding_type as the
  # serialisation-friendly slug; this lookup gives the UI a nicer
  # display string ("Follow-up" vs `:follow_up`).
  defp finding_label(:follow_up), do: "follow-up"
  defp finding_label("follow_up"), do: "follow-up"
  defp finding_label("thought"), do: "follow-up"
  defp finding_label(:thought), do: "follow-up"
  defp finding_label(other), do: to_string(other)

  # Defensive int parsing for client-sourced phx-value payloads. The
  # toolbar / filter / comment-form handlers receive these as strings
  # over the wire; a tampered client could send anything. Return
  # `:error` rather than raising so the handler can no-op instead of
  # crashing the LV (LiveView's restart would drop in-flight form
  # state).
  defp parse_int(value) when is_integer(value), do: {:ok, value}

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_int(_), do: :error

  # Stderr breadcrumb for "client sent a non-int — handler no-ops".
  # Tampering and template/JS bugs both leave a trail so a real
  # bug doesn't surface as a silent "this button doesn't work".
  defp log_ignored_event(event, field, value) do
    IO.puts(
      :stderr,
      "meerkat: #{event} ignored — non-integer #{field}: #{inspect(value)}"
    )
  end

  defp valid_diff_mode(m, _default) when m in ["split", "unified"], do: m
  defp valid_diff_mode(_, default), do: default

  defp valid_bool(b, _default) when is_boolean(b), do: b
  defp valid_bool(_, default), do: default

  defp valid_font_size(n, _default) when is_integer(n), do: clamp_font_size(n)
  defp valid_font_size(_, default), do: default

  defp valid_tab_size(n, _default) when n in [2, 4, 8], do: n
  defp valid_tab_size(_, default), do: default

  # Toolbar font-size accepts integers in [9, 28] — outside the range
  # the diff is unreadable / off the screen at typical zoom levels.
  defp clamp_font_size(n), do: n |> max(9) |> min(28)

  defp clamp_tab_size(n) when n in [2, 4, 8], do: n
  defp clamp_tab_size(_), do: 2

  defp anchor_for(:file, %{file_index: idx}), do: %{file_index: idx}

  defp anchor_for(:commit_msg, %{start_line: f, end_line: t}),
    do: %{start_line: f, end_line: t}

  defp anchor_for(:inline, %{
         file_index: idx,
         start_line: from,
         end_line: to,
         side: side
       }),
       do: %{file_index: idx, start_line: from, end_line: to, side: side}

  defp anchor_for(_, _), do: %{}

  defp find_comment(state, "global", id), do: Enum.find(state.global_comments, &(&1.id == id))
  defp find_comment(state, "file", id), do: Enum.find(state.file_comments, &(&1.id == id))

  defp find_comment(state, "commit_msg", id),
    do: Enum.find(state.commit_message_comments, &(&1.id == id))

  defp find_comment(state, "inline", id), do: Enum.find(state.comments, &(&1.id == id))

  defp global_form_props(form, review_id) do
    base_form_props(form, %{
      submitLabel: if(Map.get(form, :edit_id), do: "Save", else: "Add Global Comment"),
      draftKey: draft_key_for(:global, %{}, review_id, Map.get(form, :edit_id))
    })
  end

  defp file_form_props(form, file_index, state, review_id) do
    file = Enum.at(state.files, file_index)
    language = Map.get(file || %{}, :language, "plaintext")

    base_form_props(form, %{
      submitLabel: if(Map.get(form, :edit_id), do: "Save", else: "Add File Comment"),
      extraPayload: %{file_index: file_index},
      language: language,
      draftKey:
        draft_key_for(:file, %{file_index: file_index}, review_id, Map.get(form, :edit_id))
    })
  end

  defp commit_msg_form_props(form, review_id, commit_message) do
    %{anchor: anchor} = form

    base_form_props(form, %{
      submitLabel: if(Map.get(form, :edit_id), do: "Save", else: "Add Commit Message Comment"),
      draftKey: draft_key_for(:commit_msg, anchor, review_id, Map.get(form, :edit_id)),
      initialCode: commit_msg_seed_code(commit_message, anchor)
    })
  end

  # Build the suggestion-mode seed text for a commit-msg comment form
  # from the message lines covered by `anchor`. Opening a Suggestion-
  # type comment on a commit-msg block pre-populates the CodeMirror
  # editor with those source lines so the user edits *toward* the
  # change.
  defp commit_msg_seed_code(msg, %{start_line: s, end_line: e})
       when is_binary(msg) and is_integer(s) and is_integer(e) and s >= 1 and e >= s do
    msg
    |> String.split("\n")
    |> Enum.slice((s - 1)..(e - 1))
    |> Enum.join("\n")
  end

  defp commit_msg_seed_code(_msg, _anchor), do: ""

  # Build the inline-form descriptor passed to DiffViewer for the
  # given file index. Nil when no inline form is open for THIS file.
  # The descriptor carries the props CommentForm needs plus the
  # anchor coordinates DiffViewer uses to inject the form below the
  # right diff row.
  defp inline_form_for_diff(open_form, idx, state, review_id) do
    case open_form do
      %{surface: :inline, anchor: %{file_index: ^idx} = anchor} = form ->
        %{anchor: anchor, props: inline_form_props(form, state, review_id)}

      _ ->
        nil
    end
  end

  defp inline_form_props(form, state, review_id) do
    %{anchor: anchor} = form
    file = Enum.at(state.files, anchor.file_index)
    language = Map.get(file || %{}, :language, "plaintext")
    initial_code = extract_snippet(file, anchor.start_line, anchor.end_line, anchor.side)

    base_form_props(form, %{
      submitLabel: if(Map.get(form, :edit_id), do: "Save", else: "Add Comment"),
      extraPayload: %{
        file_index: anchor.file_index,
        start_line: anchor.start_line,
        end_line: anchor.end_line,
        side: anchor.side
      },
      language: language,
      initialCode: initial_code,
      draftKey: draft_key_for(:inline, anchor, review_id, Map.get(form, :edit_id))
    })
  end

  # Snippet of the file content covered by `start_line..end_line` on
  # the given side. Seeds the Suggestion-mode CodeMirror so the user
  # can edit-toward instead of starting from a blank slate. Returns
  # "" if the file or content is missing.
  defp extract_snippet(nil, _, _, _), do: ""

  defp extract_snippet(%{} = file, from, to, side) do
    source =
      case side do
        "new" -> Map.get(file, :new_content, "")
        :new -> Map.get(file, :new_content, "")
        "old" -> Map.get(file, :old_content, "")
        :old -> Map.get(file, :old_content, "")
        _ -> ""
      end

    case source do
      nil ->
        ""

      "" ->
        ""

      str ->
        str
        |> String.split("\n")
        |> Enum.slice((from - 1)..(to - 1))
        |> Enum.join("\n")
    end
  end

  # Draft key shape: `meerkat:draft:<review_id>:<surface>:<anchor>[:edit:<id>]`.
  # Scoping by review_id prevents one review's drafts from bleeding into
  # the next at the same anchor. Edit mode appends the comment id so
  # editing a comment doesn't share its draft with a new comment at
  # the same anchor.
  defp draft_key_for(surface, anchor, review_id, edit_id) do
    base = "meerkat:draft:#{review_id || "unbound"}:#{surface}#{anchor_suffix(anchor)}"
    if edit_id, do: "#{base}:edit:#{edit_id}", else: base
  end

  defp anchor_suffix(%{file_index: idx, start_line: f, end_line: t, side: side}),
    do: ":#{idx}:#{side}:#{f}-#{t}"

  defp anchor_suffix(%{file_index: idx}), do: ":#{idx}"

  defp anchor_suffix(%{start_line: f, end_line: t}), do: ":#{f}-#{t}"

  defp anchor_suffix(_), do: ""

  defp base_form_props(form, overrides) do
    %{
      initialBody: Map.get(form, :initial_body, ""),
      initialFindingType: Map.get(form, :initial_finding_type, "issue"),
      initialLearnFromThis: Map.get(form, :initial_learn_from_this, false)
    }
    |> Map.merge(overrides)
  end

  # Build + post a new comment on the form's surface in one call.
  # Common fields (id/body/finding_type/learn_from_this/created_at)
  # are shared; surface-specific anchor fields come from anchor_extras/2.
  defp commit_add(review_id, %{surface: surface, anchor: anchor}, body, finding, learn?) do
    base = %{
      id: Comment.new_id(),
      body: body,
      finding_type: finding,
      learn_from_this: learn?,
      created_at: Comment.now()
    }

    comment = Map.merge(base, anchor_extras(surface, anchor))
    ReviewServer.add_comment(review_id, surface, comment)
  end

  defp anchor_extras(:global, _), do: %{}
  defp anchor_extras(:file, %{file_index: idx}), do: %{file_index: idx}

  defp anchor_extras(:commit_msg, %{start_line: f, end_line: t}),
    do: %{start_line: f, end_line: t}

  defp anchor_extras(:inline, %{file_index: idx, start_line: f, end_line: t, side: side}),
    do: %{file_index: idx, start_line: f, end_line: t, side: side}
end
