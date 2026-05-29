defmodule Meerkat.ReviewTarget do
  @moduledoc """
  Sum-type for what meerkat is reviewing.

  - `{:staged, commit_msg_path | nil}` — `meerkat` or `meerkat
    --commit-msg <PATH>`. The default.
  - `{:single_ref, ref}` — `meerkat HEAD` (or any single ref). Diffs
    `<ref>~1...<ref>`.
  - `{:range, base, head, :two_dot | :three_dot}` — `meerkat A..B` or
    `meerkat A...B`.
  - `{:pr, spec}` — `meerkat --pr 123` (or a full PR URL). Resolution
    of the PR's metadata + ref fetching is deferred to ReviewState
    construction so this stays a pure parse step.
  """

  @type t ::
          {:staged, commit_msg_path :: String.t() | nil}
          | {:single_ref, ref :: String.t()}
          | {:range, base :: String.t(), head :: String.t(), :two_dot | :three_dot}
          | {:pr, spec :: String.t()}

  @doc """
  Pick a target out of the parsed-CLI option map (see `Meerkat.CLI`).
  Precedence (highest first): `--pr` > positional ref-or-range >
  `--commit-msg` > staged-no-msg default. If the caller passes
  multiple, the highest-precedence one wins silently; CLI parsing
  does not currently reject the combination.
  """
  @spec from_opts(%{
          optional(:pr) => String.t() | nil,
          optional(:positional) => String.t() | nil,
          optional(:commit_msg_path) => String.t() | nil
        }) :: t
  def from_opts(opts) do
    cond do
      opts[:pr] not in [nil, ""] -> {:pr, opts[:pr]}
      opts[:positional] not in [nil, ""] -> parse_range_or_ref(opts[:positional])
      opts[:commit_msg_path] not in [nil, ""] -> {:staged, opts[:commit_msg_path]}
      true -> {:staged, nil}
    end
  end

  # `A...B` (three-dot) matched first because `..` is a prefix of `...`.
  defp parse_range_or_ref(spec) do
    cond do
      String.contains?(spec, "...") ->
        [base, head] = String.split(spec, "...", parts: 2)
        {:range, base, head, :three_dot}

      String.contains?(spec, "..") ->
        [base, head] = String.split(spec, "..", parts: 2)
        {:range, base, head, :two_dot}

      true ->
        {:single_ref, spec}
    end
  end
end
