defmodule Meerkat.Decision do
  @moduledoc """
  Single source of truth for the review's terminal decision.

  The CLI starts and blocks on `await/0`. Two things end that wait:
  `ReviewLive` calling `submit/1` from the user's button click, and the
  review's deadline passing with nobody having clicked, unless
  `Meerkat.Timeout.action/0` is `:wait`. `current/0`
  returns the decision if it's already been made — used by
  `ReviewLive.mount/3` on a refresh-during-shutdown F5 to seed the done
  view.

  Decision shape:
  `{:approve | :approve_with_feedback | :reject | :cancel | :timeout, payload}`,
  where `payload` is the formatted feedback string for approve-with-
  feedback, reject and timeout, and the empty string otherwise.

  ## Callers

  The process that invoked meerkat (a blocked `git commit`, say) is a
  caller, and it reaches this BEAM through `MeerkatWeb.AttachController`.
  A caller can exit at any time without ending the review: the review
  keeps serving, and a later invocation of the same review attaches in
  its place. So under a launcher the CLI does not print the outcome. It
  publishes it with `publish/1`, every attached caller is sent it, and
  the CLI halts only once a caller reports it delivered. An outcome
  published with nobody attached is held for the next caller. A caller
  attaching for a different run displaces every caller already attached
  for another run: each displaced caller is sent `:meerkat_displaced`
  and is no longer tracked. Reattaching for its own run (for example,
  after a dev BEAM restart) displaces nobody, so only one invocation at
  a time waits on a review.

  The deadline runs only while a caller is attached, because it exists
  to release a caller that is waiting. Each attach arms it for that
  caller's run, and it is disarmed when the last caller detaches.
  """

  use GenServer

  require Logger

  @typedoc "Tag identifying the user's choice."
  @type tag :: :approve | :approve_with_feedback | :reject | :cancel | :timeout

  @typedoc "Decision tuple stored when submit/1 fires."
  @type decision :: {tag, term()}

  @typedoc "The exit code a caller exits with, and the text it prints to stderr."
  @type outcome :: {non_neg_integer(), String.t()}

  @deadline_topic "meerkat:deadline"

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

  @doc """
  Attach the calling process as a caller for launcher run `run_id`. It is sent
  `{:meerkat_outcome, outcome}` once the outcome is published, `:meerkat_displaced`
  once a caller for another run attaches, and is detached when it exits. Returns
  the outcome already held, if any, and `:closing` once a caller has taken
  delivery, since this BEAM is about to halt.
  """
  @spec attach(String.t()) :: {:ok, outcome | nil} | :closing
  def attach(run_id) do
    GenServer.call(__MODULE__, {:attach, self(), run_id})
  end

  @doc """
  Hold `outcome` and send it to every attached caller.
  """
  @spec publish(outcome) :: :ok
  def publish({code, text} = outcome) when is_integer(code) and is_binary(text) do
    GenServer.call(__MODULE__, {:publish, outcome})
  end

  @doc """
  Record that a caller has printed the outcome. Wakes `await_delivery/0`.
  """
  @spec delivered(String.t()) :: :ok | {:error, :no_outcome}
  def delivered(run_id) do
    GenServer.call(__MODULE__, {:delivered, run_id})
  end

  @doc """
  Returns the run of the caller that took delivery of the published
  outcome, blocking until one has.
  """
  @spec await_delivery() :: String.t()
  def await_delivery do
    GenServer.call(__MODULE__, :await_delivery, :infinity)
  end

  @doc """
  PubSub topic carrying `{:meerkat_deadline, deadline_ms | nil}` whenever
  the deadline is armed or disarmed.
  """
  @spec deadline_topic() :: String.t()
  def deadline_topic, do: @deadline_topic

  ## GenServer callbacks

  @impl true
  def init(:no_decision) do
    schedule_deadline_check()
    {:ok, initial_state()}
  end

  defp initial_state do
    %{
      decision: nil,
      waiters: [],
      outcome: nil,
      callers: %{},
      deadline_run: nil,
      delivered_to: nil,
      delivery_waiters: []
    }
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

  def handle_call(:reset, _from, %{callers: callers}) do
    Enum.each(Map.keys(callers), &Process.demonitor(&1, [:flush]))
    schedule_deadline_check()
    {:reply, :ok, initial_state()}
  end

  def handle_call({:attach, _pid, _run_id}, _from, %{delivered_to: run} = state)
      when is_binary(run) do
    {:reply, :closing, state}
  end

  def handle_call({:attach, pid, run_id}, _from, state) do
    {displaced, kept} =
      Enum.split_with(state.callers, fn {_ref, {_pid, run}} -> run != run_id end)

    Enum.each(displaced, fn {ref, {old, _run}} ->
      Process.demonitor(ref, [:flush])
      send(old, :meerkat_displaced)
    end)

    ref = Process.monitor(pid)
    state = if is_nil(state.decision), do: arm_deadline(state, run_id), else: state
    callers = kept |> Map.new() |> Map.put(ref, {pid, run_id})
    {:reply, {:ok, state.outcome}, %{state | callers: callers}}
  end

  def handle_call({:publish, outcome}, _from, state) do
    Enum.each(Map.values(state.callers), fn {pid, _run} ->
      send(pid, {:meerkat_outcome, outcome})
    end)

    {:reply, :ok, %{state | outcome: outcome}}
  end

  def handle_call({:delivered, _run_id}, _from, %{outcome: nil} = state) do
    {:reply, {:error, :no_outcome}, state}
  end

  def handle_call({:delivered, run_id}, _from, state) do
    Enum.each(state.delivery_waiters, &GenServer.reply(&1, run_id))
    {:reply, :ok, %{state | delivered_to: run_id, delivery_waiters: []}}
  end

  def handle_call(:await_delivery, _from, %{delivered_to: run} = state) when is_binary(run) do
    {:reply, run, state}
  end

  def handle_call(:await_delivery, from, state) do
    {:noreply, %{state | delivery_waiters: [from | state.delivery_waiters]}}
  end

  @impl true
  def handle_info(:check_deadline, %{decision: nil} = state) do
    deadline = Application.get_env(:meerkat, :review_deadline_ms)

    if is_integer(deadline) and Meerkat.Timeout.expired?(deadline) do
      expire(state, Meerkat.Timeout.action())
    else
      schedule_deadline_check()
      {:noreply, state}
    end
  end

  def handle_info(:check_deadline, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{callers: callers} = state)
      when is_map_key(callers, ref) do
    callers = Map.delete(callers, ref)
    if callers == %{}, do: set_deadline(nil)
    {:noreply, %{state | callers: callers}}
  end

  def handle_info(msg, state) do
    Logger.warning("Meerkat.Decision: unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  ## Internals

  defp put_decision(%{waiters: waiters} = state, decision) do
    Enum.each(waiters, &GenServer.reply(&1, decision))
    %{state | decision: decision, waiters: []}
  end

  # One timer armed for the whole window would be measured on the monotonic
  # clock, which does not advance while the machine is suspended. The tick
  # compares two wall-clock times instead, so a night asleep burns the
  # review's time.
  defp schedule_deadline_check do
    if Application.get_env(:meerkat, :review_deadline_ms) do
      Process.send_after(self(), :check_deadline, Meerkat.Timeout.check_interval_ms())
    end
  end

  defp expire(state, :wait) do
    :ok =
      Meerkat.Timeout.keep_alive(Application.get_env(:meerkat, :repo_path), state.deadline_run)

    schedule_deadline_check()
    {:noreply, state}
  end

  defp expire(state, :approve) do
    decision =
      Meerkat.Timeout.decision(
        Application.get_env(:meerkat, :repo_path),
        Application.get_env(:meerkat, :review_id)
      )

    {:noreply, put_decision(state, decision)}
  end

  # A deadline already armed has its tick running, so only a disarmed one
  # starts a new tick.
  defp arm_deadline(state, run_id) do
    was_armed? = is_integer(Application.get_env(:meerkat, :review_deadline_ms))

    set_deadline(
      Meerkat.Timeout.deadline_ms(
        Application.get_env(:meerkat, :repo_path),
        Application.get_env(:meerkat, :review_id),
        run_id
      )
    )

    unless was_armed?, do: schedule_deadline_check()
    %{state | deadline_run: run_id}
  end

  defp set_deadline(deadline_ms) do
    Application.put_env(:meerkat, :review_deadline_ms, deadline_ms)
    Phoenix.PubSub.broadcast(Meerkat.PubSub, @deadline_topic, {:meerkat_deadline, deadline_ms})
  end
end
