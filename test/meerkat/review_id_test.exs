defmodule Meerkat.ReviewIdTest do
  use ExUnit.Case, async: true

  alias Meerkat.ReviewId

  describe "derive/2" do
    test "stable for the same (repo_path, target)" do
      target = {:staged, "/tmp/MSG"}
      assert ReviewId.derive("/repo", target) == ReviewId.derive("/repo", target)
    end

    test "different repo paths produce different ids" do
      target = {:staged, nil}
      refute ReviewId.derive("/a", target) == ReviewId.derive("/b", target)
    end

    test "different targets produce different ids" do
      repo = "/repo"

      ids =
        [
          {:staged, nil},
          {:staged, "/tmp/MSG"},
          {:single_ref, "HEAD"},
          {:range, "main", "feat", :two_dot},
          {:range, "main", "feat", :three_dot},
          {:pr, "123"}
        ]
        |> Enum.map(&ReviewId.derive(repo, &1))

      assert length(Enum.uniq(ids)) == length(ids)
    end

    test "16-hex-char output" do
      id = ReviewId.derive("/repo", {:staged, nil})
      assert String.length(id) == 16
      assert id =~ ~r/^[0-9a-f]+$/
    end

    test "staged with nil and empty msg-path produce the same id" do
      assert ReviewId.derive("/repo", {:staged, nil}) == ReviewId.derive("/repo", {:staged, ""})
    end

    test "range ids distinguish base and head, not just the mode" do
      base = ReviewId.derive("/repo", {:range, "main", "feat", :two_dot})
      refute base == ReviewId.derive("/repo", {:range, "develop", "feat", :two_dot})
      refute base == ReviewId.derive("/repo", {:range, "main", "develop", :two_dot})
    end
  end
end
