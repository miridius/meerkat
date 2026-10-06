defmodule Meerkat.DecisionCase do
  @moduledoc """
  Case template for synchronous tests that can reach the singleton
  `Meerkat.Decision`, directly or through code that reads it (ReviewLive,
  ReviewServer's saves, the watchers). Each test starts with no decision
  and clears any decision it leaves, so no test inherits one.
  `MeerkatWeb.ConnCase` does the same through `reset_decision/1`.
  """

  use ExUnit.CaseTemplate

  setup tags do
    reset_decision(tags)
  end

  @doc """
  Clears the decision now and again when the test exits. Does nothing in
  an async test, which must not touch the singleton.
  """
  def reset_decision(%{async: true}), do: :ok

  def reset_decision(_tags) do
    Meerkat.Decision.reset()
    on_exit(&Meerkat.Decision.reset/0)
  end
end
