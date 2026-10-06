defmodule Meerkat.ReviewLog do
  @moduledoc """
  Persistent log of one review session. Written in `in-progress`
  state on start, rewritten with the final decision on approve /
  reject / cancel. Any I/O failure logs to stderr — logging is
  best-effort, never load-bearing. A killed process leaves the file
  at `in-progress`, which is the "review didn't complete" signal.

  On-disk shape: one JSON file per session at
  `<per-worktree-gitdir>/meerkat-precommit/reviews/<ts>-<slug>-<filetag>.json`
  where `<filetag>` is `empty` (zero changed files) or
  `files<count>`. Per-worktree so concurrent worktrees don't trample
  each other's review logs.
  """

  alias Meerkat.{ApprovalCache, Git, ReviewState}

  @version 1

  @type t :: %__MODULE__{
          path: String.t(),
          record: map()
        }

  defstruct [:path, :record]

  @doc """
  Begin a review log entry. Writes the initial `in-progress` JSON to
  `<per-worktree-gitdir>/meerkat-precommit/reviews/<ts>-<slug>-<filetag>.json`.
  """
  @spec start(String.t(), ReviewState.t()) :: t
  def start(repo_path, %ReviewState{} = state) do
    reviews_dir = reviews_dir(repo_path)
    File.mkdir_p!(reviews_dir)

    {iso, fname_ts} = now_strings()
    slug = slugify_branch(state.head_branch)
    filetag = file_tag(state.files)
    path = Path.join(reviews_dir, "#{fname_ts}-#{slug}-#{filetag}.json")

    approval_cache = ApprovalCache.load_for(repo_path)
    branch = state.head_branch

    record = %{
      version: @version,
      started_at: iso,
      finished_at: nil,
      decision: "in-progress",
      repo_path: repo_path,
      branch: branch,
      pr: pr_record(state.pr),
      commit_message: state.commit_message,
      files: Enum.map(state.files, &file_record(&1, repo_path, approval_cache, branch)),
      submission: nil,
      rendered_feedback: nil
    }

    log = %__MODULE__{path: path, record: record}
    _ = write_log(log)
    log
  end

  defp reviews_dir(repo_path) do
    Path.join(Git.meerkat_dir(repo_path), "reviews")
  end

  @doc false
  def file_tag([]), do: "empty"
  def file_tag(files), do: "files" <> Integer.to_string(length(files))

  @doc """
  Update a log entry with the final decision + rendered feedback
  (stderr text). On error, returns the log unchanged — the caller is
  exiting either way.
  """
  @spec finalize(t, atom, String.t()) :: t
  def finalize(%__MODULE__{record: record} = log, decision, rendered_feedback) do
    {iso, _} = now_strings()

    new_record =
      record
      |> Map.put(:finished_at, iso)
      |> Map.put(:decision, Atom.to_string(decision))
      |> Map.put(
        :rendered_feedback,
        if(rendered_feedback == "", do: nil, else: rendered_feedback)
      )

    updated = %{log | record: new_record}
    _ = write_log(updated)
    updated
  end

  ## Internals

  defp write_log(%__MODULE__{path: path, record: record}) do
    case Jason.encode(record) do
      {:ok, json} ->
        case Meerkat.AtomicFile.write(path, json) do
          :ok ->
            :ok

          {:error, reason} ->
            IO.puts(
              :stderr,
              "meerkat: warning — couldn't write review log to #{path}: #{inspect(reason)}"
            )

            :error
        end

      {:error, reason} ->
        IO.puts(
          :stderr,
          "meerkat: warning — couldn't encode review log: #{inspect(reason)}"
        )

        :error
    end
  end

  defp now_strings do
    now = DateTime.utc_now()
    iso = DateTime.to_iso8601(now)

    fname =
      [now.year, now.month, now.day, now.hour, now.minute, now.second]
      |> Enum.map_join("", &(Integer.to_string(&1, 10) |> String.pad_leading(2, "0")))

    {iso, fname}
  end

  @doc false
  def slugify_branch(nil), do: "no-branch"
  def slugify_branch(""), do: "no-branch"

  def slugify_branch(branch) do
    branch
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> String.slice(0, 40)
  end

  defp pr_record(nil), do: nil

  defp pr_record(pr),
    do: %{number: pr.number, title: pr.title, url: pr.url}

  # `effective_oid` is the index blob OID — populated for staged
  # reviews (where it lets the approval cache content-address)
  # and "" otherwise. `was_approved` reflects whether the file was
  # already on the approval cache when the review started, so the
  # audit log shows what state the reviewer walked into. Reads the
  # OID from the already-materialised file_diff rather than
  # re-shelling out to git.
  defp file_record(file, _repo_path, approval_cache, branch) do
    oid = Map.get(file, :effective_oid) || ""

    was_approved =
      not is_nil(branch) and oid != "" and
        ApprovalCache.approved?(approval_cache, branch, file.file_name, oid)

    %{
      file_name: file.file_name,
      effective_oid: oid,
      was_approved: was_approved
    }
  end
end
