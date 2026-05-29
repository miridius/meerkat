defmodule Meerkat.Decision do
  @moduledoc """
  Single source of truth for the review's terminal decision.

  The CLI starts and blocks on `await/0`. `ReviewLive` calls `submit/1`
  from the user's button click. `current/0` returns the decision if
  it's already been made — used by `ReviewLive.mount/3` on a
  refresh-during-shutdown F5 to seed the done view.

  Decision shape:
  `{:approve | :approve_with_feedback | :reject | :cancel, payload}`,
  where `payload` is the formatted feedback string for approve-with-
  feedback / reject and the empty string otherwise.
  """

  use GenServer

  @typedoc "Tag identifying the user's choice."
  @type tag :: :approve | :approve_with_feedback | :reject | :cancel

  @typedoc "Decision tuple stored when submit/1 fires."
  @type decision :: {tag, term()}

  ## Public API

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :no_decision, name: __MODULE__)
  end

  @doc """
  Block the caller until a decision lands. Used by the CLI's main
  loop. Returns the decision tuple.
  """
  @spec await() :: decision
  def await do
    GenServer.call(__MODULE__, :await, :infinity)
  end

  @doc """
  Submit a terminal decision. Wakes any pending `await/0` callers.
  Subsequent submits are ignored.
  """
  @spec submit(decision) :: :ok
  def submit({tag, _payload} = decision)
      when tag in [:approve, :approve_with_feedback, :reject, :cancel] do
    GenServer.call(__MODULE__, {:submit, decision})
  end

  @doc """
  Return the decision if one's been submitted, else `nil`. Used by
  ReviewLive on mount to seed the done view across LiveSocket
  reconnects.
  """
  @spec current() :: decision | nil
  def current do
    GenServer.call(__MODULE__, :current)
  end

  ## GenServer callbacks

  @impl true
  def init(:no_decision) do
    {:ok, %{decision: nil, waiters: []}}
  end

  @impl true
  def handle_call(:await, from, %{decision: nil, waiters: waiters} = state) do
    {:noreply, %{state | waiters: [from | waiters]}}
  end

  def handle_call(:await, _from, %{decision: decision} = state) do
    {:reply, decision, state}
  end

  def handle_call({:submit, decision}, _from, %{decision: nil, waiters: waiters} = state) do
    Enum.each(waiters, &GenServer.reply(&1, decision))
    {:reply, :ok, %{state | decision: decision, waiters: []}}
  end

  def handle_call({:submit, _new}, _from, %{decision: _existing} = state) do
    # First submit wins. Subsequent submits are silently ignored —
    # the CLI has already exited or is about to.
    {:reply, :ok, state}
  end

  def handle_call(:current, _from, %{decision: decision} = state) do
    {:reply, decision, state}
  end
end
