defmodule Meerkat.ReviewServer do
  @moduledoc """
  One coordinator GenServer per `review_id`, owning the canonical
  `%Meerkat.ReviewState{}` for that review.

  ## Single-writer

  All mutations route through this server. LiveViews subscribe to
  `Phoenix.PubSub` on `"review:\#{review_id}"`, never write directly.
  Server-as-truth means crashes, tab closes, and multi-tab edits all
  converge on the same state.

  ## Lifecycle

  Started lazily via `ensure_started/2` on the first LiveView mount
  for a given review_id. Subsequent mounts find the already-running
  process via the Registry. The persisted state on disk is loaded
  on `init/1`; every mutation re-persists via `Meerkat.Persistence`
  before broadcasting.
  """

  use GenServer

  alias Meerkat.{Persistence, ReviewState}

  @type review_id :: String.t()

  ## Public API

  @doc """
  Start (or find the existing) ReviewServer for `review_id`. Returns
  the pid on either path.
  """
  @spec ensure_started(review_id, %{
          repo_path: String.t(),
          initial_state: ReviewState.t()
        }) :: {:ok, pid()}
  def ensure_started(review_id, %{repo_path: _, initial_state: _} = init_args)
      when is_binary(review_id) do
    case DynamicSupervisor.start_child(
           Meerkat.ReviewServerSup,
           {__MODULE__, Map.put(init_args, :review_id, review_id)}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc "Current canonical `%ReviewState{}`."
  @spec get_state(review_id) :: ReviewState.t()
  def get_state(review_id) do
    GenServer.call(via(review_id), :get_state)
  end

  @doc "PubSub topic LiveViews subscribe to for `{:state_changed, state}` broadcasts."
  @spec topic(review_id) :: String.t()
  def topic(review_id), do: "review:#{review_id}"

  @typedoc "Comment surface — closed set."
  @type surface :: :inline | :file | :global | :commit_msg

  @doc """
  Look up the file at `idx` inside the server process and return only
  that one map. Avoids the FileContentController copying the entire
  ReviewState (with every file's old/new content) through its mailbox
  just to extract one file.
  """
  @spec get_file_at(review_id, non_neg_integer()) :: {:ok, map()} | :not_found
  def get_file_at(review_id, idx) when is_integer(idx) and idx >= 0 do
    GenServer.call(via(review_id), {:get_file_at, idx})
  end

  @doc """
  Add a comment on `surface`. `comment` must match the per-surface
  shape from `Meerkat.Comment` (`inline()` / `file()` / `global()` /
  `commit_msg()`).
  """
  @spec add_comment(review_id, surface, map()) :: ReviewState.t()
  def add_comment(review_id, surface, comment)
      when surface in [:inline, :file, :global, :commit_msg] do
    GenServer.call(via(review_id), {:add_comment, surface, comment})
  end

  @doc """
  Drop every comment across all four surfaces in a single GenServer
  call — one persist, one broadcast. Used by `decision.cancel` so the
  N comment-by-comment removal that used to flood PubSub is now
  atomic.
  """
  @spec clear_all_comments(review_id) :: ReviewState.t()
  def clear_all_comments(review_id) do
    GenServer.call(via(review_id), :clear_all_comments)
  end

  @doc """
  Remove a comment by id from any surface (inline / file / global /
  commit-msg). Caller specifies the surface so the server doesn't
  have to scan four lists.
  """
  @spec remove_comment(review_id, :inline | :file | :global | :commit_msg, String.t()) ::
          ReviewState.t()
  def remove_comment(review_id, surface, id)
      when surface in [:inline, :file, :global, :commit_msg] and is_binary(id) do
    GenServer.call(via(review_id), {:remove_comment, surface, id})
  end

  @doc """
  Flip the `learn_from_this` flag on the comment identified by
  `(surface, id)`. No-op if the id isn't found on that surface.
  """
  @spec set_learn_from_this(
          review_id,
          :inline | :file | :global | :commit_msg,
          String.t(),
          boolean()
        ) :: ReviewState.t()
  def set_learn_from_this(review_id, surface, id, learn?)
      when surface in [:inline, :file, :global, :commit_msg] and is_binary(id) and
             is_boolean(learn?) do
    GenServer.call(via(review_id), {:set_learn_from_this, surface, id, learn?})
  end

  @doc "Mark/unmark a file as reviewed (file_name granularity)."
  @spec set_approved(review_id, String.t(), boolean()) :: ReviewState.t()
  def set_approved(review_id, file_name, approved?) when is_boolean(approved?) do
    GenServer.call(via(review_id), {:set_approved, file_name, approved?})
  end

  @doc "Hide / unhide a file extension from the file-filter list."
  @spec set_extension_hidden(review_id, String.t(), boolean()) :: ReviewState.t()
  def set_extension_hidden(review_id, ext, hidden?) when is_boolean(hidden?) do
    GenServer.call(via(review_id), {:set_extension_hidden, ext, hidden?})
  end

  @doc """
  Per-file visibility override. `decision` is one of:
    :show    — force the file visible regardless of generated /
               extension / show_generated state.
    :hide    — force the file hidden.
    :default — drop any override, fall through to other filters.
  """
  @spec set_file_override(review_id, String.t(), :show | :hide | :default) :: ReviewState.t()
  def set_file_override(review_id, file_name, decision)
      when is_binary(file_name) and decision in [:show, :hide, :default] do
    GenServer.call(via(review_id), {:set_file_override, file_name, decision})
  end

  @doc "Replace the entire file_overrides map. Used by bulk actions."
  @spec set_file_overrides(review_id, %{String.t() => :show | :hide}) :: ReviewState.t()
  def set_file_overrides(review_id, overrides) when is_map(overrides) do
    GenServer.call(via(review_id), {:set_file_overrides, overrides})
  end

  @doc "Toggle the `show generated files` flag. Broadcast so other tabs converge."
  @spec set_show_generated(review_id, boolean()) :: ReviewState.t()
  def set_show_generated(review_id, show?) when is_boolean(show?) do
    GenServer.call(via(review_id), {:set_show_generated, show?})
  end

  @doc """
  Persist the currently-open comment form (which surface, anchor,
  edit context). Stored on `ReviewState.open_form` so a BEAM restart
  reopens the form at the same anchor — partial typed content is
  separately preserved by the CommentForm's localStorage draft.
  """
  @spec set_open_form(review_id, map() | nil) :: ReviewState.t()
  def set_open_form(review_id, form) when is_map(form) or is_nil(form) do
    GenServer.call(via(review_id), {:set_open_form, form})
  end

  ## GenServer plumbing

  @doc false
  def start_link(%{review_id: review_id} = init_args) do
    GenServer.start_link(__MODULE__, init_args, name: via(review_id))
  end

  defp via(review_id), do: {:via, Registry, {Meerkat.ReviewRegistry, review_id}}

  @impl true
  def init(%{review_id: review_id, repo_path: repo_path, initial_state: initial_state}) do
    # Replay any in-progress comments left behind by an earlier
    # invocation (last crash, tab close, killed process).
    state = Persistence.load(repo_path, review_id, initial_state)

    {:ok,
     %{
       review_id: review_id,
       repo_path: repo_path,
       state: state
     }}
  end

  @impl true
  def handle_call(:get_state, _from, %{state: state} = ctx), do: {:reply, state, ctx}

  def handle_call({:get_file_at, idx}, _from, %{state: state} = ctx) do
    reply =
      case Enum.at(state.files, idx) do
        nil -> :not_found
        file -> {:ok, file}
      end

    {:reply, reply, ctx}
  end

  def handle_call({:add_comment, surface, comment}, _from, ctx) do
    key = surface_key(surface)
    update(ctx, fn s -> Map.update!(s, key, fn list -> list ++ [comment] end) end)
  end

  def handle_call(:clear_all_comments, _from, ctx) do
    update(ctx, fn s ->
      %{
        s
        | comments: [],
          file_comments: [],
          global_comments: [],
          commit_message_comments: []
      }
    end)
  end

  def handle_call({:remove_comment, surface, id}, _from, ctx) do
    key = surface_key(surface)

    update(ctx, fn state ->
      Map.update!(state, key, fn list -> Enum.reject(list, fn c -> c.id == id end) end)
    end)
  end

  def handle_call({:set_learn_from_this, surface, id, learn?}, _from, ctx) do
    key = surface_key(surface)

    update(ctx, fn state ->
      Map.update!(state, key, fn list ->
        Enum.map(list, fn c ->
          if c.id == id, do: Map.put(c, :learn_from_this, learn?), else: c
        end)
      end)
    end)
  end

  def handle_call({:set_approved, file_name, true}, _from, ctx) do
    update(ctx, fn s -> Map.update!(s, :approved_file_names, &MapSet.put(&1, file_name)) end)
  end

  def handle_call({:set_approved, file_name, false}, _from, ctx) do
    update(ctx, fn s -> Map.update!(s, :approved_file_names, &MapSet.delete(&1, file_name)) end)
  end

  def handle_call({:set_extension_hidden, ext, true}, _from, ctx) do
    update(ctx, fn s -> Map.update!(s, :hidden_extensions, &MapSet.put(&1, ext)) end)
  end

  def handle_call({:set_extension_hidden, ext, false}, _from, ctx) do
    update(ctx, fn s -> Map.update!(s, :hidden_extensions, &MapSet.delete(&1, ext)) end)
  end

  def handle_call({:set_file_override, file_name, :default}, _from, ctx) do
    update(ctx, fn s -> Map.update!(s, :file_overrides, &Map.delete(&1, file_name)) end)
  end

  def handle_call({:set_file_override, file_name, decision}, _from, ctx)
      when decision in [:show, :hide] do
    update(ctx, fn s -> Map.update!(s, :file_overrides, &Map.put(&1, file_name, decision)) end)
  end

  def handle_call({:set_file_overrides, overrides}, _from, ctx) do
    update(ctx, fn s -> %{s | file_overrides: overrides} end)
  end

  def handle_call({:set_show_generated, show?}, _from, ctx) do
    update(ctx, fn s -> %{s | show_generated: show?} end)
  end

  def handle_call({:set_open_form, form}, _from, ctx) do
    update(ctx, fn s -> %{s | open_form: form} end)
  end

  defp surface_key(:inline), do: :comments
  defp surface_key(:file), do: :file_comments
  defp surface_key(:global), do: :global_comments
  defp surface_key(:commit_msg), do: :commit_message_comments

  # Run the state mutation, persist, broadcast, reply with the new
  # state — keeps the four side effects in one place so no mutation
  # path can forget any of them. Persistence failures broadcast a
  # `:persistence_failed` PubSub event so the LV can surface a
  # banner; the in-memory state remains correct, but the user needs
  # to know their typed input isn't reaching disk before the BEAM
  # dies.
  defp update(%{state: state, repo_path: repo, review_id: id} = ctx, mutate_fn) do
    new_state = mutate_fn.(state)

    case Persistence.save(repo, id, new_state) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(
          :stderr,
          "meerkat: warning — couldn't persist review #{id} state: #{inspect(reason)}. " <>
            "In-memory state preserved; comments may be lost if the BEAM dies before next save."
        )

        Phoenix.PubSub.broadcast(
          Meerkat.PubSub,
          topic(id),
          {:persistence_failed, reason}
        )
    end

    Phoenix.PubSub.broadcast(Meerkat.PubSub, topic(id), {:state_changed, new_state})
    {:reply, new_state, %{ctx | state: new_state}}
  end
end
