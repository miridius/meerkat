defmodule Meerkat.ReviewState do
  @moduledoc """
  Snapshot of "what's being reviewed" — the list of changed files, the
  commit message (if any), and the PR / branch metadata for the page
  header. Derived once via `from_target/2` and exposed to
  `MeerkatWeb.ReviewLive` via `mount/3`.
  """

  alias Meerkat.{Comment, Git, GitHub, ReviewTarget}

  defstruct files: [],
            commit_message: "",
            # commit_message split into "top-level blocks" the gutter
            # can put buttons on. Each block carries its own start/end
            # (1-indexed).
            commit_message_blocks: [],
            pr: nil,
            head_branch: nil,
            base_branch: nil,
            # Comment surfaces — populated by `Meerkat.ReviewServer`.
            comments: [],
            file_comments: [],
            global_comments: [],
            commit_message_comments: [],
            # Per-file approval (file_name) and per-extension hidden
            # set use MapSet for O(1) membership in the file-filter
            # path. MapSets serialise as JSON arrays via
            # `Meerkat.Persistence`.
            approved_file_names: MapSet.new(),
            hidden_extensions: MapSet.new(),
            # When false (default), `MeerkatWeb.ReviewLive` filters
            # `linguist-generated=true` files out of the main file
            # list. Toggle lives on ReviewState (not in-LV ephemeral)
            # so multiple tabs converge via PubSub.
            show_generated: false,
            # Per-file visibility OVERRIDE map. Each entry is
            # `{file_name, :show | :hide}` — the panel's per-row
            # checkbox always wins over hidden_extensions /
            # show_generated / any default filter. Files without an
            # entry fall through to the default-visibility rule.
            # Persisted across BEAM restart.
            file_overrides: %{},
            # In-progress open comment form (which surface, anchor,
            # edit_id). Persisted to disk so the form survives a
            # BEAM restart (DevWatcher, crash) or a fresh tab
            # reconnect. Body content is held in localStorage via
            # the form's `draftKey`, so re-opening at the same
            # anchor restores the typed text too.
            open_form: nil,
            # True for the `--commit-msg` staged-diff hook flow. False
            # for ad-hoc PR / range / single-ref reviews. Drives "is
            # Approve blocking a commit?" copy + hides the
            # Post-to-GitHub button, which doesn't make sense before
            # the commit even exists.
            precommit?: false,
            # SHA-256 over `(file_name, effective_oid)` per file —
            # computed once at construction so Persistence.save/3
            # doesn't re-hash on every mutation. `files` is frozen
            # post-mount, so the signature is too.
            state_signature: nil

  @type pr_info :: %{
          number: pos_integer(),
          title: String.t(),
          url: String.t()
        }

  @type block :: %{
          start_line: pos_integer(),
          end_line: pos_integer(),
          text: String.t()
        }

  @type t :: %__MODULE__{
          files: [Git.file_diff()],
          commit_message: String.t(),
          commit_message_blocks: [block],
          pr: pr_info | nil,
          head_branch: String.t() | nil,
          base_branch: String.t() | nil,
          comments: [Comment.inline()],
          file_comments: [Comment.file()],
          global_comments: [Comment.global()],
          commit_message_comments: [Comment.commit_msg()],
          approved_file_names: MapSet.t(String.t()),
          hidden_extensions: MapSet.t(String.t()),
          show_generated: boolean(),
          file_overrides: %{optional(String.t()) => :show | :hide},
          open_form: map() | nil,
          precommit?: boolean(),
          state_signature: String.t() | nil
        }

  @doc """
  Resolve a `ReviewTarget` into a full `%ReviewState{}`.

  The `repo_path` is the cwd the CLI was launched from — `git` reads
  config relative to it, so threading it explicitly avoids depending
  on whatever the BEAM thinks its cwd is at the moment.
  """
  @spec from_target(ReviewTarget.t(), String.t()) :: {:ok, t} | {:error, String.t()}
  def from_target({:staged, commit_msg_path}, repo_path) do
    with {:ok, files} <- Git.staged_file_diffs(repo_path) do
      msg = read_commit_msg(commit_msg_path)
      branch = Git.current_branch(repo_path)
      approved = hydrate_approved_from_cache(repo_path, branch, files)
      pr_full = Meerkat.GitHub.current_pr(repo_path)

      {:ok,
       build(
         files: files,
         commit_message: msg,
         pr: compact_pr(pr_full),
         head_branch: branch,
         base_branch: base_of(pr_full),
         approved_file_names: approved,
         precommit?: true
       )}
    end
  end

  def from_target({:single_ref, ref}, repo_path) do
    base = "#{ref}~1"
    pr_full = Meerkat.GitHub.current_pr(repo_path)

    with {:ok, files} <- Git.range_file_diffs(repo_path, base, ref, :three_dot),
         {:ok, msg} <- Git.commit_message(repo_path, ref) do
      {:ok,
       build(
         files: files,
         commit_message: msg,
         pr: compact_pr(pr_full),
         head_branch: ref,
         base_branch: base_of(pr_full) || base
       )}
    end
  end

  def from_target({:range, base, head, mode}, repo_path) do
    pr_full = Meerkat.GitHub.current_pr(repo_path)

    with {:ok, files} <- Git.range_file_diffs(repo_path, base, head, mode) do
      {:ok,
       build(
         files: files,
         commit_message: "",
         pr: compact_pr(pr_full),
         head_branch: head,
         base_branch: base_of(pr_full) || base
       )}
    end
  end

  def from_target({:pr, spec}, repo_path) do
    with {:ok, pr_json} <- GitHub.view(repo_path, spec),
         {:ok, {head_ref, base_ref}} <- Git.fetch_pr(repo_path, pr_json.number, pr_json.base_ref),
         {:ok, files} <- Git.range_file_diffs(repo_path, base_ref, head_ref, :three_dot) do
      {:ok,
       build(
         files: files,
         commit_message: pr_json.body,
         pr: %{number: pr_json.number, title: pr_json.title, url: pr_json.url},
         head_branch: pr_json.head_ref,
         base_branch: pr_json.base_ref
       )}
    end
  end

  ## Commit-message block detection

  @doc """
  Split a commit message into the gutter-renderable top-level blocks.

  Each non-empty paragraph (separated by blank lines) becomes one
  block, EXCEPT bulleted/numbered list paragraphs — every list item
  in those is its own block, so the reviewer can comment on a single
  bullet without dragging across a multi-item paragraph.

  Lines starting with `#` (git commit-message comment lines) are
  stripped from `commit_message` before the call lands here, so they
  never appear as their own block.

  Lines are 1-indexed.
  """
  @spec blocks(String.t()) :: [block]
  def blocks(""), do: []

  def blocks(message) do
    indexed = message |> String.split("\n") |> Enum.with_index(1)

    indexed
    |> split_off_fenced_code()
    |> Enum.flat_map(fn
      {:code, lines} -> [lines]
      {:prose, lines} -> lines |> chunk_paragraphs() |> Enum.flat_map(&split_list_items/1)
    end)
    |> Enum.map(fn lines ->
      {_first_text, first_idx} = hd(lines)
      {_last_text, last_idx} = List.last(lines)

      %{
        start_line: first_idx,
        end_line: last_idx,
        text: lines |> Enum.map(fn {t, _} -> t end) |> Enum.join("\n")
      }
    end)
  end

  # Walk the indexed lines and split out fenced code blocks
  # (`` ``` ``-delimited) as single units so the gutter doesn't anchor
  # comments to the fence delimiters. Everything else is returned in
  # `:prose` chunks for the paragraph / list-item splitter to handle.
  defp split_off_fenced_code(indexed_lines), do: split_off_fenced_code(indexed_lines, [], [])

  defp split_off_fenced_code([], prose_acc, out) do
    finalise =
      case Enum.reverse(prose_acc) do
        [] -> out
        lines -> [{:prose, lines} | out]
      end

    Enum.reverse(finalise)
  end

  defp split_off_fenced_code([{text, idx} | rest], prose_acc, out) do
    if fence?(text) do
      out2 =
        case Enum.reverse(prose_acc) do
          [] -> out
          prose -> [{:prose, prose} | out]
        end

      {code_lines, rest2} = collect_until_close_fence(rest, [{text, idx}])
      split_off_fenced_code(rest2, [], [{:code, code_lines} | out2])
    else
      split_off_fenced_code(rest, [{text, idx} | prose_acc], out)
    end
  end

  defp collect_until_close_fence([], acc), do: {Enum.reverse(acc), []}

  defp collect_until_close_fence([{text, idx} | rest], acc) do
    if fence?(text),
      do: {Enum.reverse([{text, idx} | acc]), rest},
      else: collect_until_close_fence(rest, [{text, idx} | acc])
  end

  defp fence?(text) do
    trimmed = String.trim_leading(text)
    String.starts_with?(trimmed, "```") or String.starts_with?(trimmed, "~~~")
  end

  # Group the indexed lines by blank-line separators. Returns a list of
  # paragraphs, each a non-empty list of `{text, line_no}`.
  defp chunk_paragraphs(indexed_lines) do
    indexed_lines
    |> Enum.chunk_by(fn {text, _} -> String.trim(text) == "" end)
    |> Enum.reject(fn chunk ->
      match?([{<<>>, _} | _], chunk) or
        Enum.all?(chunk, fn {text, _} -> String.trim(text) == "" end)
    end)
  end

  # If every line of the paragraph looks like a list item, each
  # becomes its own block; otherwise the paragraph stays as one block.
  defp split_list_items(paragraph) do
    if Enum.all?(paragraph, fn {text, _} -> list_item?(text) end) do
      Enum.map(paragraph, &[&1])
    else
      [paragraph]
    end
  end

  defp list_item?(text) do
    text = String.trim_leading(text)

    String.starts_with?(text, "- ") or
      String.starts_with?(text, "* ") or
      Regex.match?(~r/^\d+[.)] /, text)
  end

  ## Internals

  defp read_commit_msg(nil), do: ""

  defp read_commit_msg(path) do
    case File.read(path) do
      {:ok, content} -> content |> strip_git_comments() |> String.trim()
      {:error, _} -> ""
    end
  end

  # `git commit -e` injects `# Please enter the commit message…` lines
  # the editor strips on save. Meerkat does the same.
  defp strip_git_comments(content) do
    content
    |> String.split("\n")
    |> Enum.reject(fn line -> String.starts_with?(String.trim_leading(line), "#") end)
    |> Enum.join("\n")
  end

  defp compact_pr(nil), do: nil
  defp compact_pr(pr), do: %{number: pr.number, title: pr.title, url: pr.url}

  defp base_of(%{base_ref: base}) when is_binary(base) and base != "", do: base
  defp base_of(_), do: nil

  defp build(opts) do
    msg = Keyword.fetch!(opts, :commit_message)
    files = Keyword.fetch!(opts, :files)

    state = %__MODULE__{
      files: files,
      commit_message: msg,
      commit_message_blocks: blocks(msg),
      pr: Keyword.get(opts, :pr),
      head_branch: Keyword.get(opts, :head_branch),
      base_branch: Keyword.get(opts, :base_branch),
      approved_file_names: Keyword.get(opts, :approved_file_names, MapSet.new()),
      precommit?: Keyword.get(opts, :precommit?, false)
    }

    %{state | state_signature: Meerkat.Persistence.state_signature(state)}
  end

  # Pre-populate the approved set from the per-branch approval cache.
  # If a file's current staged blob OID matches one this branch
  # already approved, tick it on mount so the reviewer doesn't have
  # to re-tick on every round.
  defp hydrate_approved_from_cache(_repo_path, nil, _files), do: MapSet.new()

  defp hydrate_approved_from_cache(repo_path, branch, files) do
    cache = Meerkat.ApprovalCache.load_for(repo_path)
    approved_from_cache(cache, branch, files)
  end

  # `effective_oid` is already on every file_diff (populated by
  # materialise_staged at mount), so no per-file git shell-out is
  # needed. Deletions carry their HEAD pre-image OID, so they re-hydrate
  # like any other file; `""` is the failed-lookup case and matches
  # nothing.
  defp approved_from_cache(cache, branch, files) do
    files
    |> Enum.filter(fn %{file_name: name, effective_oid: oid} ->
      is_binary(oid) and oid != "" and
        Meerkat.ApprovalCache.approved?(cache, branch, name, oid)
    end)
    |> Enum.map(& &1.file_name)
    |> MapSet.new()
  end

  @doc false
  def approved_from_cache_for_test(cache, branch, files),
    do: approved_from_cache(cache, branch, files)
end
