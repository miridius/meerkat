defmodule Meerkat.Decision do
  @moduledoc """
  Single source of truth for the review's terminal decision.

  The CLI starts and blocks on `await/0`. Two things end that wait:
  `ReviewLive` calling `submit/1` from the user's button click, and the
  review's deadline passing with nobody having clicked. `current/0`
  returns the decision if it's already been made — used by
  `ReviewLive.mount/3` on a refresh-during-shutdown F5 to seed the done
  view.

  Decision shape:
  `{:approve | :approve_with_feedback | :reject | :cancel | :timeout, payload}`,
  where `payload` is the formatted feedback string for approve-with-
  feedback, reject and timeout, and the empty string otherwise.
  """

  use GenServer

  require Logger

  @typedoc "Tag identifying the user's choice."
  @type tag :: :approve | :approve_with_feedback | :reject | :cancel | :timeout

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
  @spec submit(decision) :: {:ok, decision} | {:already_decided, decision}
  def submit({tag, _payload} = decision)
      when tag in [:approve, :approve_with_feedback, :reject, :cancel, :timeout] do
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

  @doc """
  Clear any submitted decision, returning to the pre-submit state.
  Test-support only — production never un-makes a terminal decision.
  Resetting in place (rather than restarting the process) keeps the
  supervisor's restart budget intact across a test run.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  ## GenServer callbacks

  @impl true
  def init(:no_decision) do
    schedule_deadline_check()
    {:ok, %{decision: nil, waiters: []}}
  end

  @impl true
  def handle_call(:await, from, %{decision: nil, waiters: waiters} = state) do
    {:noreply, %{state | waiters: [from | waiters]}}
  end

  def handle_call(:await, _from, %{decision: decision} = state) do
    {:reply, decision, state}
  end

  def handle_call({:submit, decision}, _from, %{decision: nil} = state) do
    {:reply, {:ok, decision}, put_decision(state, decision)}
  end

  def handle_call({:submit, _new}, _from, %{decision: existing} = state) do
    {:reply, {:already_decided, existing}, state}
  end

  def handle_call(:current, _from, %{decision: decision} = state) do
    {:reply, decision, state}
  end

  def handle_call(:reset, _from, _state) do
    schedule_deadline_check()
    {:reply, :ok, %{decision: nil, waiters: []}}
  end

  @impl true
  def handle_info(:check_deadline, %{decision: nil} = state) do
    deadline = Application.get_env(:meerkat, :review_deadline_ms)

    if is_integer(deadline) and Meerkat.Timeout.expired?(deadline) do
      {:noreply, put_decision(state, timed_out_decision())}
    else
      schedule_deadline_check()
      {:noreply, state}
    end
  end

  def handle_info(:check_deadline, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.warning("Meerkat.Decision: unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  ## Internals

  defp put_decision(%{waiters: waiters} = state, decision) do
    Enum.each(waiters, &GenServer.reply(&1, decision))
    %{state | decision: decision, waiters: []}
  end

  # Re-check on a repeating tick rather than arming one timer for the whole
  # window: Erlang timers run on the monotonic clock, which macOS stops
  # advancing while the machine sleeps, so a lid closed for two hours would
  # burn none of the review's time.
  defp schedule_deadline_check do
    if Application.get_env(:meerkat, :review_deadline_ms) do
      Process.send_after(self(), :check_deadline, Meerkat.Timeout.check_interval_ms())
    end
  end

  defp timed_out_decision do
    Meerkat.Timeout.decision(
      Application.get_env(:meerkat, :repo_path),
      Application.get_env(:meerkat, :review_id)
    )
  end
end
