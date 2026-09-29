defmodule Meerkat.OpenForms do
  @moduledoc """
  The comment forms a review has open, in the order they were opened.

  Each form is a map with a `:surface` (`:global`, `:file`,
  `:commit_msg` or `:inline`), an `:anchor`, and for edit forms an
  `:edit_id` plus the prefill fields. A form's `key/1` names its
  surface, anchor and edit target, so several forms can be open at
  once and each submit or cancel acts on the form it came from. The
  key is also part of each form's localStorage `draftKey`, so
  changing its format orphans drafts saved under the old one.
  """

  @type form :: %{
          required(:surface) => atom(),
          required(:anchor) => map(),
          optional(atom()) => any()
        }

  @doc """
  Identify `form` by surface, anchor and edit target, for example
  `"inline:0:new:4-6"` or `"global:edit:abc"`.
  """
  @spec key(form()) :: String.t()
  def key(%{surface: surface, anchor: anchor} = form) do
    base = "#{surface}#{anchor_suffix(anchor)}"

    case Map.get(form, :edit_id) do
      nil -> base
      id -> "#{base}:edit:#{id}"
    end
  end

  defp anchor_suffix(%{file_index: idx, start_line: f, end_line: t, side: side}),
    do: ":#{idx}:#{side}:#{f}-#{t}"

  defp anchor_suffix(%{file_index: idx}), do: ":#{idx}"
  defp anchor_suffix(%{start_line: f, end_line: t}), do: ":#{f}-#{t}"
  defp anchor_suffix(_), do: ""

  @doc """
  Append `form` to `forms`. Opening a form whose key is already open
  is a no-op, so keys stay unique and the form keeps its place.
  """
  @spec open([form()], form()) :: [form()]
  def open(forms, form) do
    k = key(form)
    if Enum.any?(forms, &(key(&1) == k)), do: forms, else: forms ++ [form]
  end

  @doc "Drop the form whose key is `key` from `forms`."
  @spec close([form()], String.t()) :: [form()]
  def close(forms, key), do: Enum.reject(forms, &(key(&1) == key))

  @doc "The form whose key is `key`, or nil."
  @spec find([form()], String.t()) :: form() | nil
  def find(forms, key), do: Enum.find(forms, &(key(&1) == key))
end
