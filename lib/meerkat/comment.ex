defmodule Meerkat.Comment do
  @moduledoc """
  Shapes + finding-type validation for the four comment kinds the
  review UI supports. All four share an `id`, `body`, `finding_type`,
  `learn_from_this`, and `created_at`; per-kind fields layer on top.

  `finding_type` is one of `:issue | :suggestion | :question |
  :follow_up | :revert` — Conventional Comments-flavoured. `revert`
  asks the agent to undo a change. `follow_up` flags work to save
  for later (not a fix-now instruction). The list is closed; the UI
  maps each value to a colour in `InlineComment.svelte`.
  """

  @type id :: String.t()
  @type finding_type :: :issue | :suggestion | :question | :follow_up | :revert
  @type side :: :old | :new

  @typedoc """
  Inline comment anchored to a file + line range on the diff body.
  """
  @type inline :: %{
          id: id,
          file_index: non_neg_integer(),
          start_line: pos_integer(),
          end_line: pos_integer(),
          side: side,
          body: String.t(),
          finding_type: finding_type,
          learn_from_this: boolean(),
          created_at: String.t()
        }

  @typedoc "File-level comment (the file as a whole, no line anchor)."
  @type file :: %{
          id: id,
          file_index: non_neg_integer(),
          body: String.t(),
          finding_type: finding_type,
          learn_from_this: boolean(),
          created_at: String.t()
        }

  @typedoc "Page-level (global) comment, not bound to any file."
  @type global :: %{
          id: id,
          body: String.t(),
          finding_type: finding_type,
          learn_from_this: boolean(),
          created_at: String.t()
        }

  @typedoc "Commit-message gutter comment anchored to a line range."
  @type commit_msg :: %{
          id: id,
          start_line: pos_integer(),
          end_line: pos_integer(),
          body: String.t(),
          finding_type: finding_type,
          learn_from_this: boolean(),
          created_at: String.t()
        }

  @finding_types ~w(issue suggestion question follow_up revert)a

  @doc "True iff the argument is one of the five allowed finding-type atoms."
  @spec finding_type?(term()) :: boolean()
  def finding_type?(value), do: value in @finding_types

  @doc "The closed set of finding-type atoms."
  @spec finding_types() :: [finding_type]
  def finding_types, do: @finding_types

  @doc "Fresh comment id (RFC4122 v4 UUID). Opaque to consumers."
  @spec new_id() :: id
  def new_id do
    <<a::32, b::16, _::4, c::12, _::2, d::62>> = :crypto.strong_rand_bytes(16)
    # Stamp the version (4) and variant (10xx) bits before formatting
    # so the resulting hex is unambiguously RFC 4122 v4.
    <<a1::32, b1::16, c1::16, d1::16, e1::48>> = <<a::32, b::16, 4::4, c::12, 2::2, d::62>>

    # `:io_lib.format` with zero-padded `~*.16.0b` produces the right
    # width per segment in one pass — no post-hoc String.pad_leading
    # dance for the leading-zero case.
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a1, b1, c1, d1, e1])
    |> IO.iodata_to_binary()
  end

  @doc """
  Current timestamp as ISO 8601 UTC — the format the persisted JSON
  uses for `created_at`.
  """
  @spec now() :: String.t()
  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
