defmodule Meerkat.Persistence do
  @moduledoc """
  Atomic save / load for `%Meerkat.ReviewState{}` snapshots.

  The on-disk shape is JSON at
  `<gitdir>/meerkat-precommit/in-progress/<review_id>.json`.

  ## What's persistable

  The mutable user-input subset survives a crash: all four comment
  surfaces, per-file approvals, hidden-extension filters, per-file
  visibility overrides, the show-generated toggle, and the in-flight
  comment-form anchor (`open_form`). `files`, `commit_message`,
  `commit_message_blocks`, `pr`, and branch metadata are re-derived
  from git on mount, so they're not persisted. The terminal decision
  is owned by `Meerkat.Decision` and is reset on each invocation.

  ## Atomicity

  Saves write to `<file>.tmp.<rand>` and `File.rename/2` into place.
  `rename/2` is atomic within a filesystem; readers see either the
  old contents or the new ones, never a half-written file.
  """

  alias Meerkat.ReviewState

  @persistable_keys [
    :comments,
    :file_comments,
    :global_comments,
    :commit_message_comments,
    :approved_file_names,
    :hidden_extensions,
    :file_overrides,
    :show_generated,
    :open_form,
    :state_signature
  ]

  @doc """
  Save the persistable subset of `state` to
  `<gitdir>/meerkat-precommit/in-progress/<review_id>.json`. Creates
  the parent directory if it doesn't exist.
  """
  @spec save(String.t(), String.t(), ReviewState.t()) :: :ok | {:error, term()}
  def save(repo_path, review_id, %ReviewState{} = state) do
    path = path_for(repo_path, review_id)
    Meerkat.AtomicFile.write(path, encode!(state))
  end

  @doc """
  Load the persistable subset for `review_id` and merge it into
  `state`. Returns `state` unchanged if no save exists. A malformed /
  corrupt snapshot is logged to stderr and renamed to `.corrupt.<ts>`
  so the next save doesn't overwrite a file the user might still
  want to recover comments from.
  """
  @spec load(String.t(), String.t(), ReviewState.t()) :: ReviewState.t()
  def load(repo_path, review_id, %ReviewState{} = state) do
    path = path_for(repo_path, review_id)
    current_sig = current_signature(state)

    case File.read(path) do
      {:ok, json} ->
        case safe_decode(json) do
          {:ok, decoded} ->
            case Map.get(decoded, :state_signature) do
              ^current_sig ->
                merge(state, decoded)

              nil ->
                # Legacy snapshot without a signature — keep the prior
                # restore-on-restart behaviour. New saves will write
                # the signature so the next mismatch can be detected.
                merge(state, decoded)

              _other ->
                # Stale snapshot — staged content differs from what
                # this session is reviewing. Drop the file so the
                # previous session's comments don't leak into this
                # one. If the rm fails (permissions / NFS replay /
                # another process holding the file), quarantine
                # under .corrupt.<ts> so the next boot doesn't loop
                # on the same mismatch and re-print "discarded".
                case File.rm(path) do
                  :ok ->
                    IO.puts(
                      :stderr,
                      "meerkat: discarding stale in-progress snapshot at #{path} (different staged state)"
                    )

                  {:error, rm_reason} ->
                    quarantine(path, "stale snapshot rm failed: #{inspect(rm_reason)}")
                end

                state
            end

          {:error, reason} ->
            quarantine(path, reason)
            state
        end

      {:error, :enoent} ->
        state

      {:error, reason} ->
        IO.puts(
          :stderr,
          "meerkat: warning — couldn't read in-progress snapshot at #{path}: #{inspect(reason)}"
        )

        state
    end
  end

  @doc """
  Fingerprint the current review's staged content as a hex string. Two
  invocations against the same staged tree (same file names + blob
  OIDs) produce the same signature; any change to either set produces
  a different one. Stored in the persistence JSON so a leftover
  snapshot from a previous attempt can be detected and discarded.
  """
  @spec state_signature(ReviewState.t()) :: String.t()
  def state_signature(%ReviewState{files: files}) do
    files
    |> Enum.map(fn f -> "#{Map.get(f, :file_name)}\t#{Map.get(f, :effective_oid)}" end)
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  # `state.files` is frozen post-mount, so the SHA-256 is identical
  # for every save fired from the same session. Read the cached
  # signature off the state struct if it's there; fall back to a
  # live hash otherwise (legacy / test paths).
  defp current_signature(%ReviewState{state_signature: sig}) when is_binary(sig), do: sig
  defp current_signature(state), do: state_signature(state)

  @doc """
  Delete the on-disk snapshot. Called when a review reaches a
  terminal decision (approve / reject / cancel) — the next
  invocation should start fresh.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(repo_path, review_id) do
    path = path_for(repo_path, review_id)

    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        IO.puts(
          :stderr,
          "meerkat: warning — couldn't delete in-progress snapshot at #{path}: #{inspect(reason)}. " <>
            "Next review may show stale state."
        )

        :ok
    end
  end

  @doc """
  Filesystem path the snapshot for `review_id` lives at. Resolved via
  `git rev-parse --git-dir` so secondary worktrees get per-worktree
  storage rather than colliding under the main `.git/meerkat-precommit`.
  """
  @spec path_for(String.t(), String.t()) :: String.t()
  def path_for(repo_path, review_id) do
    Path.join([Meerkat.Git.meerkat_dir(repo_path), "in-progress", "#{review_id}.json"])
  end

  ## Encoding / decoding

  @doc false
  @spec encode!(ReviewState.t()) :: String.t()
  def encode!(%ReviewState{} = state) do
    state
    |> persistable_map()
    |> Jason.encode!()
  end

  # `keys: :atoms!` raises ArgumentError on unknown keys — anything not
  # in the existing atom table is corrupt for our purposes.
  defp safe_decode(json) do
    case Jason.decode(json, keys: :atoms!) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, "expected JSON object, got something else"}
      {:error, %Jason.DecodeError{} = err} -> {:error, Exception.message(err)}
    end
  rescue
    e in ArgumentError ->
      # `:atoms!` raises ArgumentError when an atom isn't already in
      # the table — that's the dominant cause and points at a
      # different-version writer. Surface the raw message too so a
      # genuinely-corrupt file doesn't get misdiagnosed as a version
      # mismatch.
      msg = Exception.message(e)

      if msg =~ "atom" do
        {:error, "unknown key (atom not yet defined; file likely from a different version)"}
      else
        {:error, msg}
      end
  end

  defp quarantine(path, reason) do
    Meerkat.Quarantine.move(
      path,
      reason,
      "in-progress snapshot",
      " Starting from an empty state."
    )
  end

  defp persistable_map(state) do
    state
    |> Map.from_struct()
    |> Map.put(:state_signature, current_signature(state))
    |> Map.take(@persistable_keys)
    |> Enum.map(&serialise/1)
    |> Map.new()
  end

  defp serialise({:approved_file_names, mapset}),
    do: {:approved_file_names, MapSet.to_list(mapset)}

  defp serialise({:hidden_extensions, mapset}), do: {:hidden_extensions, MapSet.to_list(mapset)}

  # file_overrides: %{file_name => :show | :hide}. JSON keys are
  # strings, values are atoms — encode values as strings on save
  # so the decode round-trip with keys: :atoms! doesn't choke on
  # dynamic file_name keys (they're already strings).
  defp serialise({:file_overrides, map}) when is_map(map) do
    {:file_overrides, Map.new(map, fn {k, v} -> {k, to_string(v)} end)}
  end

  # open_form holds atom keys (`:surface`, `:anchor`) that Jason
  # encodes fine, but the round-trip via `keys: :atoms!` requires
  # those atoms to exist on load. They're declared on the LV at
  # boot, so the simple Map.from_struct/.put path is enough.
  defp serialise({:open_form, nil}), do: {:open_form, nil}

  defp serialise({:open_form, form}) when is_map(form) do
    {:open_form, normalise_form(form)}
  end

  defp serialise(other), do: other

  # Convert atoms to strings before JSON encode so the form round-
  # trips deterministically (the `:atoms!` decode path requires
  # every atom to pre-exist, which fails for dynamic keys like the
  # surface name during a fresh boot).
  defp normalise_form(form) do
    %{
      "surface" => to_string(form.surface),
      "anchor" => stringify_keys(Map.get(form, :anchor, %{})),
      "edit_id" => Map.get(form, :edit_id),
      "initial_body" => Map.get(form, :initial_body),
      "initial_finding_type" => Map.get(form, :initial_finding_type),
      "initial_learn_from_this" => Map.get(form, :initial_learn_from_this)
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(other), do: other

  defp merge(state, decoded) do
    # `:state_signature` is a freshness check we serialise / read in
    # `load/3`; we don't carry it onto the in-memory ReviewState
    # because it's recomputed from the live struct on each save.
    merge_keys = @persistable_keys -- [:state_signature]

    Enum.reduce(merge_keys, state, fn key, acc ->
      case Map.get(decoded, key) do
        nil -> acc
        value -> Map.put(acc, key, deserialise(key, value))
      end
    end)
  end

  defp deserialise(:approved_file_names, list) when is_list(list), do: MapSet.new(list)
  defp deserialise(:hidden_extensions, list) when is_list(list), do: MapSet.new(list)

  # Migrate the old `thought` finding-type to its new name `follow_up`.
  # Persisted in-progress comments written before the rename surface
  # with `finding_type: "thought"` — rewrite on load so the UI + the
  # finding_atom!/1 dispatcher only need to know the new name.
  defp deserialise(key, list)
       when key in [:comments, :file_comments, :global_comments, :commit_message_comments] and
              is_list(list) do
    Enum.map(list, &migrate_finding_type/1)
  end

  # Keys come back as strings (atoms-only-applies-to-known-keys on
  # decode), values as strings. Decode the values back to :show /
  # :hide atoms.
  defp deserialise(:file_overrides, map) when is_map(map) do
    Map.new(map, fn
      {k, "show"} -> {to_string(k), :show}
      {k, "hide"} -> {to_string(k), :hide}
      {k, :show} -> {to_string(k), :show}
      {k, :hide} -> {to_string(k), :hide}
      kv -> kv
    end)
  end

  defp deserialise(:open_form, nil), do: nil

  defp deserialise(:open_form, form) when is_map(form) do
    surface = surface_atom(Map.get(form, "surface") || Map.get(form, :surface))
    anchor = atomise_anchor(Map.get(form, "anchor") || Map.get(form, :anchor) || %{})

    base = %{
      surface: surface,
      anchor: anchor
    }

    [
      {:edit_id, "edit_id"},
      {:initial_body, "initial_body"},
      {:initial_finding_type, "initial_finding_type"},
      {:initial_learn_from_this, "initial_learn_from_this"}
    ]
    |> Enum.reduce(base, fn {atom, str}, acc ->
      case Map.get(form, str) || Map.get(form, atom) do
        nil -> acc
        v -> Map.put(acc, atom, v)
      end
    end)
  end

  defp deserialise(_, value), do: value

  defp migrate_finding_type(%{finding_type: "thought"} = c),
    do: Map.put(c, :finding_type, "follow_up")

  defp migrate_finding_type(%{finding_type: :thought} = c),
    do: Map.put(c, :finding_type, :follow_up)

  defp migrate_finding_type(c), do: c

  defp surface_atom("inline"), do: :inline
  defp surface_atom("file"), do: :file
  defp surface_atom("global"), do: :global
  defp surface_atom("commit_msg"), do: :commit_msg
  defp surface_atom(atom) when is_atom(atom), do: atom
  defp surface_atom(_), do: :inline

  # Anchor keys are `:file_index`, `:start_line`, `:end_line`, `:side`.
  # All are well-known and pre-existing as atoms in the LV module.
  defp atomise_anchor(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {anchor_key(k), v} end)
  end

  defp anchor_key("file_index"), do: :file_index
  defp anchor_key("start_line"), do: :start_line
  defp anchor_key("end_line"), do: :end_line
  defp anchor_key("side"), do: :side
  defp anchor_key(k) when is_atom(k), do: k
  defp anchor_key(other), do: other
end
