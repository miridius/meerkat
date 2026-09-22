defmodule Meerkat.Git do
  @moduledoc """
  Thin wrapper around the `git` CLI for the bits the review UI needs:
  the changed-file list and per-file diff bodies for staged / range / PR
  review targets, plus commit-message lookup and PR ref fetching.

  Errors are returned as `{:error, reason}`; callers (CLI, ReviewLive)
  surface them rather than swallowing.
  """

  @typedoc "Status of a single file in a diff."
  @type status :: :added | :modified | :deleted | :renamed

  @typedoc "One changed file, before any diff body has been computed."
  @type file_entry :: %{
          status: status,
          file_name: String.t(),
          old_file_name: String.t() | nil
        }

  @typedoc """
  One changed file with diff body — Svelte's `@git-diff-view` consumes
  this shape via `DiffFile.createInstance` (see `assets/svelte/DiffViewer.svelte`).
  Snake-cased keys on both sides; LiveSvelte serialises Elixir maps
  directly so what the LV sends is what the component reads.

  `read_errors` is a list of human-readable git error messages
  collected while materialising this file's diff body. Empty in the
  normal case; populated when a `git show` or `git diff` failed
  (missing ref, corrupt object, IO error). The DiffViewer renders the
  list as a red banner above the diff so the reviewer doesn't approve
  what looks like an empty diff that's really a swallowed git error.
  """
  @type file_diff :: %{
          status: status,
          file_name: String.t(),
          old_file_name: String.t() | nil,
          old_content: String.t(),
          new_content: String.t(),
          hunks: [String.t()],
          read_errors: [String.t()],
          # Blob OID the approval cache content-addresses against: the
          # index blob for added/modified/renamed files, the HEAD
          # pre-image blob for a deletion (the content being removed).
          # `""` when that lookup failed (the LV approve guard treats it
          # as "stale, refresh"); `nil` when the diff has no staging
          # concept (range / PR mode), where the guard skips entirely.
          effective_oid: String.t() | nil,
          moved_lines: [Meerkat.Moves.moved_block()],
          is_generated: boolean()
        }

  @doc """
  Return the staged-vs-HEAD changed-file list. If the working dir has
  no commits yet, every staged file is reported as `:added`.
  """
  @spec staged_files(String.t()) :: {:ok, [file_entry]} | {:error, String.t()}
  def staged_files(repo_path) do
    # `-z` produces NUL-separated output so file names with spaces work
    # without shell quoting. Rename detection is git's default and we
    # let it stand — copies are coalesced into renames downstream.
    case run_git(repo_path, ["diff", "--cached", "--name-status", "-z"]) do
      {:ok, output} -> {:ok, parse_name_status(output)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Return the changed-file list between two refs.

  - `:two_dot` — `git diff base..head`, the symmetric delta.
  - `:three_dot` — `git diff $(git merge-base base head)..head`, "what's
    on head's side of the fork". Matches `A...B` git range syntax and
    is the right thing for PR review.
  """
  @spec range_files(String.t(), String.t(), String.t(), :two_dot | :three_dot) ::
          {:ok, [file_entry]} | {:error, String.t()}
  def range_files(repo_path, base, head, mode) do
    range =
      case mode do
        :two_dot -> "#{base}..#{head}"
        :three_dot -> "#{base}...#{head}"
      end

    case run_git(repo_path, ["diff", "--name-status", "-z", range]) do
      {:ok, output} -> {:ok, parse_name_status(output)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Return the current symbolic branch name, or `nil` if HEAD is
  detached / the lookup fails. Used by the page header chip when the
  review target doesn't carry an explicit branch (staged mode).
  """
  @spec current_branch(String.t()) :: String.t() | nil
  def current_branch(repo_path) do
    case run_git(repo_path, ["symbolic-ref", "--short", "-q", "HEAD"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          name -> name
        end

      {:error, _} ->
        nil
    end
  end

  @doc """
  Tagged staged-blob-OID lookup. Distinguishes "file is not staged"
  (a normal outcome) from "git failed to look it up" (a real problem
  worth surfacing) and from a successful read. Used by the LV's
  stale-OID guard so the user sees a specific error instead of a
  generic "stale" message on a transient git failure.
  """
  @spec fetch_staged_blob_oid(String.t(), String.t()) ::
          {:ok, String.t()} | :not_staged | {:error, String.t()}
  def fetch_staged_blob_oid(repo_path, path) do
    case run_git(repo_path, ["--literal-pathspecs", "ls-files", "-s", "--", path]) do
      {:ok, ""} ->
        :not_staged

      {:ok, output} ->
        # Format: `<mode> <oid> <stage>\t<path>`
        case String.split(String.trim(output), [" ", "\t"], parts: 4) do
          [_mode, oid | _] -> {:ok, oid}
          _ -> {:error, "unexpected `git ls-files -s` output for #{path}: #{inspect(output)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Return the blob OID for `path` in the index, or `""` if the file
  isn't staged / git can't resolve it. Thin wrapper over
  `fetch_staged_blob_oid/2` for call sites that store the OID into a
  field that uses `""` as the missing-OID sentinel (the file_diff
  type — see `effective_oid`).
  """
  @spec staged_blob_oid(String.t(), String.t()) :: String.t()
  def staged_blob_oid(repo_path, path) do
    case fetch_staged_blob_oid(repo_path, path) do
      {:ok, oid} -> oid
      :not_staged -> ""
      {:error, _} -> ""
    end
  end

  @doc """
  Batched index-blob-OID lookup. One `git ls-files -s -- <paths>`
  shell-out for the whole list; missing-from-index paths simply don't
  appear in the result map. Caller uses `Map.get(map, name, "")` to
  preserve the same "" sentinel as `staged_blob_oid/2`.
  """
  @spec staged_blob_oids_many(String.t(), [String.t()]) ::
          {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def staged_blob_oids_many(_repo_path, []), do: {:ok, %{}}

  def staged_blob_oids_many(repo_path, paths) when is_list(paths) do
    # `core.quotePath=false` so a non-ASCII path comes back raw, matching
    # the `file_name` keys (which come from `--name-status -z`, never
    # quoted); the default C-quoting would never match and the approval
    # would silently fail to persist.
    args = ["--literal-pathspecs", "-c", "core.quotePath=false", "ls-files", "-s", "--"]

    case run_git(repo_path, args ++ paths) do
      {:ok, output} ->
        map =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            # `<mode> <oid> <stage>\t<path>`
            case String.split(line, [" ", "\t"], parts: 4) do
              [_mode, oid, _stage, path] -> Map.put(acc, path, oid)
              _ -> acc
            end
          end)

        {:ok, map}

      {:error, reason} ->
        msg =
          "couldn't compute batched staged-blob OIDs (#{reason}); approve guard may flag " <>
            "files as stale"

        IO.puts(:stderr, "meerkat: warning — #{msg}")
        {:error, msg}
    end
  end

  @doc """
  Batched HEAD (pre-image) blob-OID lookup. One `git ls-tree HEAD --
  <paths>` shell-out; missing paths simply don't appear in the map.
  """
  @spec head_blob_oids_many(String.t(), [String.t()]) ::
          {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def head_blob_oids_many(_repo_path, []), do: {:ok, %{}}

  def head_blob_oids_many(repo_path, paths) when is_list(paths) do
    # `core.quotePath=false` for the same raw-path-matching reason as
    # `staged_blob_oids_many`.
    args = ["--literal-pathspecs", "-c", "core.quotePath=false", "ls-tree", "HEAD", "--"]

    case run_git(repo_path, args ++ paths) do
      {:ok, output} ->
        map =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            # `<mode> <type> <oid>\t<path>`
            case String.split(line, [" ", "\t"], parts: 4) do
              [_mode, _type, oid, path] -> Map.put(acc, path, oid)
              _ -> acc
            end
          end)

        {:ok, map}

      {:error, reason} ->
        msg =
          "couldn't compute batched HEAD-blob OIDs (#{reason}); deletion approvals may not persist"

        IO.puts(:stderr, "meerkat: warning — #{msg}")
        {:error, msg}
    end
  end

  @doc """
  Blob OID each staged file's approval is content-addressed against:
  the index blob for added / modified / renamed files, the HEAD
  pre-image blob for deletions (the content being removed). Missing
  paths are absent from the map; callers use `Map.get(map, name, "")`.

  Returns `{:error, _}` only on an index-lookup failure; a failed HEAD
  lookup degrades the affected deletions to "".
  """
  @spec effective_oids_many(String.t(), [file_entry]) ::
          {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def effective_oids_many(repo_path, entries) when is_list(entries) do
    {deleted, present} = Enum.split_with(entries, &(&1.status == :deleted))

    with {:ok, index_oids} <-
           staged_blob_oids_many(repo_path, Enum.map(present, & &1.file_name)) do
      head_oids =
        case head_blob_oids_many(repo_path, Enum.map(deleted, & &1.file_name)) do
          {:ok, map} -> map
          {:error, _} -> %{}
        end

      {:ok, Map.merge(index_oids, head_oids)}
    end
  end

  @doc """
  Batched `linguist-generated` lookup — one `git check-attr`
  shell-out for every path supplied. Returns a map of `path =>
  {:generated, boolean} | {:error, reason}`, holding an entry for
  every path passed in.

  Materialise + auto-approve both consume the same map so we don't
  spawn `git check-attr` per file twice. Failure cases are explicit
  so callers can decide whether to surface (DiffViewer red banner)
  or treat as "not generated" (auto-approve fast path stays safe by
  not treating an errored lookup as approved).
  """
  @spec linguist_generated_many(String.t(), [String.t()]) :: %{
          String.t() => {:generated, boolean()} | {:error, String.t()}
        }
  def linguist_generated_many(_repo_path, []), do: %{}

  def linguist_generated_many(repo_path, paths) when is_list(paths) do
    # `git check-attr <attr> -- <paths>` takes paths positionally and
    # answers every path in a single shell-out, so running it for the
    # whole list keeps cost flat. Passing the paths via `--stdin`
    # would have a smaller argv, but `System.cmd` can't write to a
    # spawned process's stdin without falling back to a Port +
    # close-after-write that races the child's read; positional args
    # avoid that race entirely.
    args = ["check-attr", "-z", "linguist-generated", "--"] ++ paths

    case run_git_unmerged(repo_path, args) do
      {:ok, output} ->
        # Key on the path git echoes, which `-z` gives back exactly as
        # passed. Zipping the values onto the argument list by position
        # hands one file's answer to another whenever the rows drift.
        answered =
          output
          |> String.split(<<0>>)
          |> Enum.chunk_every(3, 3, :discard)
          |> Map.new(fn [path, _attr, value] ->
            {path, {:generated, value in ["true", "set"]}}
          end)

        Map.new(paths, fn p ->
          {p, Map.get(answered, p, {:error, "`git check-attr` returned no row for #{p}"})}
        end)

      {:error, reason} ->
        msg =
          "couldn't read `linguist-generated` attribute (#{reason}). " <>
            "Check your `.gitattributes` syntax."

        IO.puts(:stderr, "meerkat: WARNING — #{msg}")
        Map.new(paths, fn p -> {p, {:error, msg}} end)
    end
  end

  @doc """
  Single-path convenience around `linguist_generated_many/2`. Returns
  `false` on error (auto-approve must NOT treat an unknown file as
  generated — that would short-circuit the UI on a transient git
  failure). For UI surfaces that need the error itself, use
  `linguist_generated_many/2`.
  """
  @spec linguist_generated?(String.t(), String.t()) :: boolean
  def linguist_generated?(repo_path, path) do
    case Map.get(linguist_generated_many(repo_path, [path]), path) do
      {:generated, bool} -> bool
      {:error, _} -> false
      nil -> false
    end
  end

  @doc """
  Return the set of local branch names — `git for-each-ref
  refs/heads/`. Used to prune the approval cache of branches that no
  longer exist. Returns `{:error, _}` on git failure; callers no-op
  rather than treating "no branches" as truth (which would wipe the
  cache).
  """
  @spec local_branches(String.t()) :: {:ok, MapSet.t(String.t())} | {:error, String.t()}
  def local_branches(repo_path) do
    case run_git(repo_path, ["for-each-ref", "--format=%(refname:short)", "refs/heads/"]) do
      {:ok, output} ->
        {:ok, output |> String.split("\n", trim: true) |> MapSet.new()}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Resolve the per-worktree gitdir via `git rev-parse --git-dir`. In a
  secondary worktree this is `.git/worktrees/<name>`; in the main
  worktree it's `.git`. Returns the absolute path. Per-worktree state
  (in-progress reviews, review logs, pending-answers) goes under here.

  Returns `{:error, _}` when `repo_path` is not itself a git repo
  (rev-parse walks upward by default; we constrain it to
  `repo_path` via `GIT_CEILING_DIRECTORIES` so we don't accidentally
  land in an ancestor repo and pollute its gitdir).
  """
  @spec git_dir(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def git_dir(repo_path) do
    case run_git_ceilinged(repo_path, ["rev-parse", "--git-dir"]) do
      {:ok, output} -> {:ok, output |> String.trim() |> Path.expand(repo_path)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Resolve the shared gitdir via `git rev-parse --git-common-dir`. All
  worktrees of the same repo share this. Cross-worktree state
  (approval cache) goes under here. Same ceiling rule as `git_dir/1`.
  """
  @spec git_common_dir(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def git_common_dir(repo_path) do
    case run_git_ceilinged(repo_path, ["rev-parse", "--git-common-dir"]) do
      {:ok, output} -> {:ok, output |> String.trim() |> Path.expand(repo_path)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Resolve the worktree root holding `path` via `git rev-parse
  --show-toplevel`. Unlike `git_dir/1` it walks upward without a
  ceiling, so `meerkat --answers` works from any subdirectory.
  """
  @spec toplevel(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def toplevel(path) do
    case run_git(path, ["rev-parse", "--show-toplevel"]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Per-worktree meerkat state directory: `<gitdir>/meerkat-precommit`,
  for the worktree holding `repo_path`. A subdirectory of the
  worktree resolves to the same directory as its root, so state
  stored by one call is found by the next whatever directory it runs
  in. Falls back to `<repo_path>/.git/meerkat-precommit` where
  `repo_path` is in no repo, or the rev-parse misbehaves. Use this as
  the base for any per-worktree path (in-progress snapshots, review
  logs, pending-answers).

  Reads the cached value from `Application.get_env(:meerkat,
  :meerkat_dir)` when present so the LV's per-mutation save path
  doesn't re-shell-out to `git rev-parse` on every keystroke.
  Falls back to a live `git_dir/1` lookup when the env isn't set
  (test paths, ad-hoc callers).
  """
  @spec meerkat_dir(String.t()) :: String.t()
  def meerkat_dir(repo_path) do
    case Application.get_env(:meerkat, :meerkat_dir) do
      nil -> resolve_meerkat_dir(repo_path)
      cached -> cached
    end
  end

  defp resolve_meerkat_dir(repo_path) do
    # Resolve the worktree root first, so a path inside a repo lands on
    # that repo's gitdir however deep it sits. A path in no repo has no
    # root to find, and `git_dir/1`'s ceiling then keeps the fallback
    # local instead of walking up into an ancestor repo.
    root =
      case toplevel(repo_path) do
        {:ok, root} -> root
        {:error, _} -> repo_path
      end

    base =
      case git_dir(root) do
        {:ok, dir} -> dir
        {:error, _} -> Path.join(root, ".git")
      end

    Path.join(base, "meerkat-precommit")
  end

  @doc """
  Read a commit message from the given commit ref via
  `git log -1 --format=%B`. Used when the user passes a single ref like
  `meerkat HEAD` and wants the commit's own message in the gutter.
  """
  @spec commit_message(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def commit_message(repo_path, ref) do
    case run_git(repo_path, ["log", "-1", "--format=%B", ref]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Return staged-vs-HEAD diffs as `[%file_diff{}]`. Each entry has the
  full old/new content + hunks the Svelte DiffViewer needs.

  Files whose entire staged diff is whitespace-only (under `-w`) are
  dropped — the reviewer doesn't want noise on reformat-only commits.
  Whitespace-only files are still surfaced if the user explicitly
  staged them via `git add -p` *with* non-whitespace edits elsewhere
  in the same file; only entries that come back with zero hunks under
  `-w` are filtered.
  """
  @spec staged_file_diffs(String.t()) :: {:ok, [file_diff]} | {:error, String.t()}
  def staged_file_diffs(repo_path) do
    with {:ok, entries} <- staged_files(repo_path) do
      names = Enum.map(entries, & &1.file_name)
      generated_map = linguist_generated_many(repo_path, names)
      # One `git diff --cached -U3 -w -M` for ALL paths instead of
      # one per file. Likewise for the effective-OID lookup.
      # On batched-call failure we surface the error into every
      # file's `read_errors` (red banner) — silently empty hunks
      # would let a reviewer approve what looks like an empty diff.
      {hunks_map, batched_hunks_error} =
        case staged_hunks_many(repo_path) do
          {:ok, map, parse_errors} -> {map, parse_errors}
          {:error, reason} -> {%{}, [reason]}
        end

      {oid_map, batched_oids_error} =
        case effective_oids_many(repo_path, entries) do
          {:ok, map} -> {map, []}
          {:error, reason} -> {%{}, [reason]}
        end

      global_read_errors = batched_hunks_error ++ batched_oids_error

      diffs =
        entries
        |> Enum.map(fn entry ->
          file = materialise_staged(repo_path, entry, generated_map, hunks_map, oid_map)
          %{file | read_errors: file.read_errors ++ global_read_errors}
        end)
        |> Enum.reject(&whitespace_only?/1)
        |> Meerkat.Moves.detect()

      {:ok, diffs}
    end
  end

  # Batched `git diff --cached -U3 -w -M` for the whole staged set.
  # Returns `{:ok, %{file_name => {hunks, errors}}} | {:error, reason}`.
  # `file_name` is the post-image path (the rename target for renames).
  # Splitting on `^diff --git ` lets us peel one block per file out of
  # the single shell-out's stdout.
  #
  # `-c core.quotePath=false` forces git to emit non-ASCII paths
  # literally instead of C-style escaping them; `parse_diff_block`
  # extracts the post-image path from the `+++ b/<path>` line which is
  # whitespace-unambiguous (one token per line, ends at newline) — the
  # `diff --git a/<old> b/<new>` header is ambiguous when paths contain
  # a literal ` b/` because git uses spaces to separate old/new.
  @spec staged_hunks_many(String.t()) ::
          {:ok, %{String.t() => {[String.t()], [String.t()]}}, [String.t()]}
          | {:error, String.t()}
  defp staged_hunks_many(repo_path) do
    args = ["-c", "core.quotePath=false", "diff", "--cached", "-U3", "-w", "-M"]

    case run_git(repo_path, args) do
      {:ok, output} ->
        {map, parse_errors} = parse_multi_file_diff(output)
        {:ok, map, parse_errors}

      {:error, reason} ->
        msg =
          "couldn't compute batched staged diff (#{reason}); per-file content may render empty"

        IO.puts(:stderr, "meerkat: warning — #{msg}")
        {:error, msg}
    end
  end

  @doc false
  # Test seam for `parse_multi_file_diff/1` — exposes the
  # multi-file-diff parser via the same return shape it produces
  # inside `staged_hunks_many`.
  def parse_multi_file_diff_for_test(output), do: parse_multi_file_diff(output)

  defp parse_multi_file_diff(""), do: {%{}, []}

  defp parse_multi_file_diff(output) do
    output
    |> String.split(~r/^(?=diff --git )/m, trim: true)
    |> Enum.reduce({%{}, []}, fn block, {acc, errors} ->
      case parse_diff_block(block) do
        {:ok, name, hunks, block_errors} ->
          {Map.put(acc, name, {hunks, block_errors}), errors}

        :error ->
          # Unparseable block — the caller can't attribute the failure
          # to a file (the block's own header is what failed to parse),
          # so every staged file takes the error and carries the red
          # banner. Dropping the block silently would take a file the
          # reviewer never saw out of the review.
          msg =
            "couldn't parse staged-diff block (first line: " <>
              "#{block |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 200)}); " <>
              "a file's diff may be missing"

          IO.puts(:stderr, "meerkat: warning — #{msg}")
          {acc, errors ++ [msg]}
      end
    end)
  end

  # Extract the post-image path from `+++ b/<path>` (always on its own
  # line, so whitespace-unambiguous). For deletions (`+++ /dev/null`)
  # there's no post-image path; fall through to the `--- a/<path>`
  # pre-image. Returns `{:ok, name, hunks}` or `:error` if the block
  # has neither marker (malformed git output).
  defp parse_diff_block(block) do
    case extract_diff_block_path(block) do
      nil ->
        parse_binary_block(block)

      name ->
        hunks =
          block
          |> String.split(~r/^(?=@@ )/m, trim: true)
          |> Enum.filter(&String.starts_with?(&1, "@@"))
          |> Meerkat.Intraline.split()

        {:ok, name, hunks, []}
    end
  end

  # A binary file's block carries no `+++`/`---` markers at all, so the
  # only path git gives us is the ambiguous `diff --git a/<old> b/<new>`
  # header. Take it when both sides name the same file, which every
  # binary block does except a rename.
  defp parse_binary_block(block) do
    with true <- binary_block?(block),
         name when is_binary(name) <- binary_block_path(block) do
      {:ok, name, [], ["binary file: git reports no text diff"]}
    else
      _ -> :error
    end
  end

  defp binary_block?(block) do
    block
    |> String.split("\n")
    |> Enum.any?(&(String.starts_with?(&1, "Binary files ") or &1 == "GIT binary patch"))
  end

  defp binary_block_path(block) do
    case block |> String.split("\n", parts: 2) |> hd() do
      "diff --git " <> rest -> same_sided_path(rest)
      _ -> nil
    end
  end

  defp same_sided_path(rest) do
    parts = String.split(rest, " ")

    Enum.find_value(1..(length(parts) - 1)//1, fn i ->
      old = parts |> Enum.take(i) |> Enum.join(" ") |> side_path("a/")
      new = parts |> Enum.drop(i) |> Enum.join(" ") |> side_path("b/")
      if old != nil and old == new, do: new
    end)
  end

  defp extract_diff_block_path(block) do
    lines = String.split(block, "\n")
    extract_marker_path(lines, "+++ ", "b/") || extract_marker_path(lines, "--- ", "a/")
  end

  defp extract_marker_path(lines, marker, side) do
    Enum.find_value(lines, fn line ->
      case line do
        ^marker <> rest when rest != "" ->
          # Strip the optional `\t<timestamp/mode>` suffix git appends
          # in some configurations. A file name can contain a space but
          # not a tab, and a quoted one carries `\t` as two characters.
          rest |> String.split("\t", parts: 2) |> hd() |> side_path(side)

        _ ->
          nil
      end
    end)
  end

  # `core.quotePath=false` stops git C-quoting a non-ASCII path, but it
  # still quotes one holding a `"`, a `\` or a control character, so
  # undo that before the `a/`/`b/` prefix comes off.
  defp side_path(str, side) do
    path = unquote_git_path(str)

    if String.starts_with?(path, side) do
      path |> String.replace_prefix(side, "") |> trim_or_nil()
    end
  end

  defp unquote_git_path(<<?", rest::binary>>), do: unescape_git_path(rest, <<>>)
  defp unquote_git_path(path), do: path

  defp unescape_git_path(<<>>, acc), do: acc
  defp unescape_git_path(<<?", _rest::binary>>, acc), do: acc

  defp unescape_git_path(<<?\\, a, b, c, rest::binary>>, acc)
       when a in ?0..?7 and b in ?0..?7 and c in ?0..?7 do
    byte = (a - ?0) * 64 + (b - ?0) * 8 + (c - ?0)
    unescape_git_path(rest, <<acc::binary, byte>>)
  end

  defp unescape_git_path(<<?\\, ch, rest::binary>>, acc) do
    unescape_git_path(rest, <<acc::binary, escaped_byte(ch)>>)
  end

  defp unescape_git_path(<<ch, rest::binary>>, acc) do
    unescape_git_path(rest, <<acc::binary, ch>>)
  end

  defp escaped_byte(?n), do: ?\n
  defp escaped_byte(?t), do: ?\t
  defp escaped_byte(?r), do: ?\r
  defp escaped_byte(?a), do: 0x07
  defp escaped_byte(?b), do: 0x08
  defp escaped_byte(?f), do: 0x0C
  defp escaped_byte(?v), do: 0x0B
  defp escaped_byte(ch), do: ch

  defp trim_or_nil(""), do: nil
  defp trim_or_nil(s), do: s

  # Drop modified files with no remaining hunks under `-w`. Added /
  # deleted / renamed still surface even with empty hunks, because the
  # file existence change itself is information the reviewer wants.
  defp whitespace_only?(%{status: :modified, hunks: [], read_errors: []}), do: true
  defp whitespace_only?(_), do: false

  @doc """
  Return range-diff entries with bodies. `mode` is `:two_dot` or
  `:three_dot` — same semantics as `range_files/4`.
  """
  @spec range_file_diffs(String.t(), String.t(), String.t(), :two_dot | :three_dot) ::
          {:ok, [file_diff]} | {:error, String.t()}
  def range_file_diffs(repo_path, base, head, mode) do
    with {:ok, entries} <- range_files(repo_path, base, head, mode) do
      effective_base = effective_base_ref(repo_path, base, head, mode)
      generated_map = linguist_generated_many(repo_path, Enum.map(entries, & &1.file_name))

      diffs =
        entries
        |> Enum.map(&materialise_range(repo_path, &1, effective_base, head, generated_map))
        |> Meerkat.Moves.detect()

      {:ok, diffs}
    end
  end

  @doc """
  Fetch a GitHub PR's head and base into local refs:

      git fetch --force origin
        +refs/pull/<n>/head:refs/meerkat-pr/<n>/head
        +refs/heads/<base>:refs/meerkat-pr/<n>/base

  Returns `{:ok, {head_ref, base_ref}}` on success.
  """
  @spec fetch_pr(String.t(), pos_integer(), String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, String.t()}
  def fetch_pr(repo_path, pr_number, base_branch) do
    head_ref = "refs/meerkat-pr/#{pr_number}/head"
    base_ref = "refs/meerkat-pr/#{pr_number}/base"

    args = [
      "fetch",
      "--force",
      "origin",
      "+refs/pull/#{pr_number}/head:#{head_ref}",
      "+refs/heads/#{base_branch}:#{base_ref}"
    ]

    case run_git(repo_path, args) do
      {:ok, _} -> {:ok, {head_ref, base_ref}}
      {:error, _} = err -> err
    end
  end

  ## Internals

  # GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE / GIT_COMMON_DIR /
  # GIT_OBJECT_DIRECTORY / GIT_ALTERNATE_OBJECT_DIRECTORIES /
  # GIT_NAMESPACE all override git's discovery process when set —
  # making `cd:` and `GIT_CEILING_DIRECTORIES` irrelevant. The
  # lefthook pre-commit / pre-push / post-merge hooks set these so
  # meerkat-invoked-from-a-hook ends up resolving paths against the
  # parent repo's gitdir instead of the cwd the caller asked for.
  # Pass them as `{key, nil}` to `System.cmd` to strip from the child
  # env. Same shape as `scripts/install.sh:91-97`'s `unset GIT_*`.
  @git_discovery_env_overrides Enum.map(
                                 ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
                                    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
                                    GIT_NAMESPACE),
                                 &{&1, nil}
                               )

  defp run_git(repo_path, args) do
    case System.cmd("git", args,
           cd: repo_path,
           stderr_to_stdout: true,
           env: @git_discovery_env_overrides
         ) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        {:error, "git #{Enum.join(args, " ")} exited #{code}: #{String.trim(output)}"}
    end
  end

  # Like `run_git/2`, but leaving git's stderr where git put it. A
  # warning about `.gitattributes` syntax merged into the NUL-separated
  # `check-attr` answer lands inside the first path it reports.
  # Only read-only lookups run here, so the failing command is safe to
  # run a second time, merged, for the reason git wrote to stderr.
  defp run_git_unmerged(repo_path, args) do
    case System.cmd("git", args, cd: repo_path, env: @git_discovery_env_overrides) do
      {output, 0} -> {:ok, output}
      {_output, _code} -> run_git(repo_path, args)
    end
  end

  # Like `run_git/2` but with `GIT_CEILING_DIRECTORIES` set to the
  # parent of `repo_path`, so rev-parse can't escape upward into an
  # ancestor git repo. Used by `git_dir/1` / `git_common_dir/1` —
  # everything else WANTS the natural upward walk (e.g. running
  # `git status` from a subdir).
  defp run_git_ceilinged(repo_path, args) do
    ceiling = Path.dirname(Path.expand(repo_path))

    case System.cmd("git", args,
           cd: repo_path,
           stderr_to_stdout: true,
           env: [{"GIT_CEILING_DIRECTORIES", ceiling} | @git_discovery_env_overrides]
         ) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        {:error, "git #{Enum.join(args, " ")} exited #{code}: #{String.trim(output)}"}
    end
  end

  ## Body materialisation
  #
  # `git show :0:path` reads from the index (staged); `git show HEAD:path`
  # reads from the last commit. For a fresh repo (no HEAD) the HEAD
  # read fails → empty old_content + an error recorded in :read_errors
  # for the reviewer to see. Added files have no old_content; deleted
  # files have no new_content.
  #
  # Staged diff hunks pass `-w` so whitespace-only changes don't show
  # up as noise on reformat commits (see `whitespace_only?/1`).

  defp materialise_staged(
         repo_path,
         %{status: :deleted, file_name: name},
         generated_map,
         hunks_map,
         oid_map
       ) do
    {old, errs1} = read_file_at(repo_path, "HEAD", name)
    {hunks, errs2} = Map.get(hunks_map, name, {[], []})
    {is_gen, errs_gen} = lookup_generated(generated_map, name)

    %{
      status: :deleted,
      file_name: name,
      old_file_name: nil,
      old_content: old,
      new_content: "",
      hunks: hunks,
      read_errors: errs1 ++ errs2 ++ errs_gen,
      effective_oid: Map.get(oid_map, name, ""),
      is_generated: is_gen
    }
  end

  defp materialise_staged(
         repo_path,
         %{status: :added, file_name: name},
         generated_map,
         hunks_map,
         oid_map
       ) do
    {new, errs1} = read_index(repo_path, name)
    {hunks, errs2} = Map.get(hunks_map, name, {[], []})
    {is_gen, errs_gen} = lookup_generated(generated_map, name)

    %{
      status: :added,
      file_name: name,
      old_file_name: nil,
      old_content: "",
      new_content: new,
      hunks: hunks,
      read_errors: errs1 ++ errs2 ++ errs_gen,
      effective_oid: Map.get(oid_map, name, ""),
      is_generated: is_gen
    }
  end

  defp materialise_staged(
         repo_path,
         %{status: :renamed, file_name: name, old_file_name: old},
         generated_map,
         hunks_map,
         oid_map
       ) do
    {old_content, errs1} = read_file_at(repo_path, "HEAD", old || name)
    {new_content, errs2} = read_index(repo_path, name)
    {hunks, errs3} = Map.get(hunks_map, name, {[], []})
    {is_gen, errs_gen} = lookup_generated(generated_map, name)

    %{
      status: :renamed,
      file_name: name,
      old_file_name: old,
      old_content: old_content,
      new_content: new_content,
      hunks: hunks,
      read_errors: errs1 ++ errs2 ++ errs3 ++ errs_gen,
      effective_oid: Map.get(oid_map, name, ""),
      is_generated: is_gen
    }
  end

  defp materialise_staged(
         repo_path,
         %{status: :modified, file_name: name},
         generated_map,
         hunks_map,
         oid_map
       ) do
    {old, errs1} = read_file_at(repo_path, "HEAD", name)
    {new, errs2} = read_index(repo_path, name)
    {hunks, errs3} = Map.get(hunks_map, name, {[], []})
    {is_gen, errs_gen} = lookup_generated(generated_map, name)

    %{
      status: :modified,
      file_name: name,
      old_file_name: nil,
      old_content: old,
      new_content: new,
      hunks: hunks,
      read_errors: errs1 ++ errs2 ++ errs3 ++ errs_gen,
      effective_oid: Map.get(oid_map, name, ""),
      is_generated: is_gen
    }
  end

  defp materialise_range(repo_path, entry, base_ref, head_ref, generated_map) do
    name = entry.file_name
    old_name = entry.old_file_name || name

    diff_args =
      case entry.status do
        :renamed ->
          [
            "--literal-pathspecs",
            "diff",
            "-U3",
            "-M",
            "#{base_ref}..#{head_ref}",
            "--",
            old_name,
            name
          ]

        _ ->
          ["--literal-pathspecs", "diff", "-U3", "#{base_ref}..#{head_ref}", "--", name]
      end

    {old, errs_old} =
      if entry.status == :added, do: {"", []}, else: read_file_at(repo_path, base_ref, old_name)

    {new, errs_new} =
      if entry.status == :deleted, do: {"", []}, else: read_file_at(repo_path, head_ref, name)

    {hunks, errs_h} = hunks_for_path(repo_path, diff_args)
    {is_gen, errs_gen} = lookup_generated(generated_map, name)

    %{
      status: entry.status,
      file_name: name,
      old_file_name: entry.old_file_name,
      old_content: old,
      new_content: new,
      hunks: hunks,
      read_errors: errs_old ++ errs_new ++ errs_h ++ errs_gen,
      # `nil` flags "no staging concept" (range / PR review) — the
      # stale-OID guard in `MeerkatWeb.ReviewLive` skips when it sees
      # nil; an empty-string OID is the failure case for staged mode
      # and is treated as "refresh and try again".
      effective_oid: nil,
      is_generated: is_gen
    }
  end

  @doc false
  # Test seam for `lookup_generated/2` — the batched map's error and
  # missing entries are what a caller never produces on demand.
  def lookup_generated_for_test(generated_map, name), do: lookup_generated(generated_map, name)

  # Pull the per-file linguist-generated answer out of the batched map.
  # `{:generated, bool}` → use; `{:error, msg}` or missing → surface
  # the failure via :read_errors AND treat as not-generated (so
  # auto-approve never short-circuits on a transient git failure).
  defp lookup_generated(generated_map, name) do
    case Map.get(generated_map, name) do
      {:generated, bool} -> {bool, []}
      {:error, msg} -> {false, ["linguist-generated check failed for #{name}: #{msg}"]}
      nil -> {false, []}
    end
  end

  # `:three_dot` resolves to merge-base via `git merge-base base head`
  # so the diff matches what `A...B` git syntax produces.
  defp effective_base_ref(repo_path, base, head, :three_dot) do
    case run_git(repo_path, ["merge-base", base, head]) do
      {:ok, sha} ->
        String.trim(sha)

      {:error, reason} ->
        IO.puts(
          :stderr,
          "meerkat: warning — couldn't resolve merge-base for #{base}...#{head}: #{reason}. " <>
            "Falling back to two-dot diff against #{base}."
        )

        base
    end
  end

  defp effective_base_ref(_repo_path, base, _head, :two_dot), do: base

  # Read a file at a specific revision. Returns `{content, errors}`:
  # on git failure, `content = ""` AND a human-readable error is
  # appended so the UI can surface "couldn't read X — diff may be
  # inaccurate" rather than silently showing an empty file.
  defp read_file_at(repo_path, ref, path) do
    case run_git(repo_path, ["show", "#{ref}:#{path}"]) do
      {:ok, content} ->
        {content, []}

      {:error, reason} ->
        msg = "couldn't read #{path} at #{ref}: #{reason}"
        IO.puts(:stderr, "meerkat: warning — #{msg}")
        {"", [msg]}
    end
  end

  # Read the staged (index) version of a file. `:0:path` selects the
  # index; identical to `git diff --cached`'s "after" side. The stage is
  # explicit so a path like `0:foo` is not taken for a stage number.
  defp read_index(repo_path, path) do
    case run_git(repo_path, ["show", ":0:#{path}"]) do
      {:ok, content} ->
        {content, []}

      {:error, reason} ->
        msg = "couldn't read staged content for #{path}: #{reason}"
        IO.puts(:stderr, "meerkat: warning — #{msg}")
        {"", [msg]}
    end
  end

  # Run `git diff …` for a single file, strip the file header, return
  # `{hunks, errors}`. `@git-diff-view` wants ONE unified-diff string
  # per file (assembled in DiffViewer.svelte) with multiple `@@…@@`
  # blocks within it; we pass them through verbatim.
  defp hunks_for_path(repo_path, diff_args) do
    case run_git(repo_path, diff_args) do
      {:ok, ""} ->
        {[], []}

      {:ok, output} ->
        # Drop the leading `diff --git`, `index`, `---`, `+++` lines.
        # Keep everything from the first `@@` onwards, then split into
        # one string per `@@` block and pass through `Intraline.split`
        # so unequal-count add/del runs are pair-aligned for intra-line
        # highlighting.
        hunks =
          output
          |> String.split(~r/^(?=@@ )/m, trim: true)
          |> Enum.filter(&String.starts_with?(&1, "@@"))
          |> Meerkat.Intraline.split()

        {hunks, []}

      {:error, reason} ->
        msg = "couldn't compute diff (args: #{Enum.join(diff_args, " ")}): #{reason}"
        IO.puts(:stderr, "meerkat: warning — #{msg}")
        {[], [msg]}
    end
  end

  @doc false
  # Parse `git diff --name-status -z` output. The format pairs
  # NUL-separated entries:
  #
  #   M\0path\0
  #   A\0path\0
  #   D\0path\0
  #   R<score>\0old\0new\0
  #   C<score>\0old\0new\0   (copies are coalesced into renames)
  #
  # Public-but-internal so unit tests can feed pre-captured git
  # output directly.
  def parse_name_status(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> consume_entries([])
    |> Enum.reverse()
  end

  defp consume_entries([], acc), do: acc

  defp consume_entries([code, old, new | rest], acc)
       when binary_part(code, 0, 1) in ["R", "C"] do
    consume_entries(rest, [%{status: :renamed, file_name: new, old_file_name: old} | acc])
  end

  defp consume_entries([<<"A", _::binary>>, path | rest], acc) do
    consume_entries(rest, [%{status: :added, file_name: path, old_file_name: nil} | acc])
  end

  defp consume_entries([<<"D", _::binary>>, path | rest], acc) do
    consume_entries(rest, [%{status: :deleted, file_name: path, old_file_name: nil} | acc])
  end

  defp consume_entries([<<"M", _::binary>>, path | rest], acc) do
    consume_entries(rest, [%{status: :modified, file_name: path, old_file_name: nil} | acc])
  end

  defp consume_entries([<<"T", _::binary>>, path | rest], acc) do
    # Type change (e.g. file ↔ symlink). Treat as modified for the
    # purposes of the file list — the diff body will tell the real
    # story.
    consume_entries(rest, [%{status: :modified, file_name: path, old_file_name: nil} | acc])
  end

  defp consume_entries([unrecognised | _], _acc) do
    raise "Meerkat.Git: unrecognised --name-status code #{inspect(unrecognised)}"
  end
end
