defmodule Meerkat.ReviewId do
  @moduledoc """
  Stable identifier for a review; keys the on-disk persistence file and
  the `Meerkat.ReviewServer` Registry entry. `derive/2` hashes the
  repository path plus the review target: for a staged review, the
  commit-msg file path (not its contents or the staged content); for a
  single ref, the ref; for a range, the base, head, and mode; or, for a
  PR, the PR spec. Editing the commit message therefore keeps the same
  `review_id`.
  """

  alias Meerkat.ReviewTarget

  @doc """
  Derive a 16-hex-char id for `(repo_path, target)`. The 64-bit
  birthday-bound is fine for the use case — at most a handful of
  in-progress reviews per repo at any time.
  """
  @spec derive(String.t(), ReviewTarget.t()) :: String.t()
  def derive(repo_path, target) do
    parts =
      case target do
        {:staged, msg_path} -> ["staged", msg_path || ""]
        {:single_ref, ref} -> ["ref", ref]
        {:range, base, head, mode} -> ["range", base, head, Atom.to_string(mode)]
        {:pr, spec} -> ["pr", spec]
      end

    key = Enum.join([repo_path | parts], "\0")
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end
end
