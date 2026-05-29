defmodule Meerkat.GitHubTest do
  use ExUnit.Case, async: true

  # decode_pr/1 is private; we exercise it through the public-but-
  # internal `decode_pr_for_test/1` exposed at the bottom of the
  # module so tests don't have to set up the gh stub for the
  # serialisation path.
  alias Meerkat.GitHub

  describe "decode_pr/1 (via test seam)" do
    test "happy path: every documented key populates" do
      json = %{
        "number" => 42,
        "baseRefName" => "main",
        "headRefName" => "feat/x",
        "title" => "Add feature",
        "body" => "Long description.",
        "url" => "https://github.com/o/r/pull/42"
      }

      assert GitHub.decode_pr_for_test(json) == %{
               number: 42,
               base_ref: "main",
               head_ref: "feat/x",
               title: "Add feature",
               body: "Long description.",
               url: "https://github.com/o/r/pull/42"
             }
    end

    test "coerces stringified number (defensive against gh shape drift)" do
      json = %{
        "number" => "42",
        "baseRefName" => "main",
        "headRefName" => "feat/x",
        "title" => "x",
        "body" => "",
        "url" => ""
      }

      assert %{number: 42} = GitHub.decode_pr_for_test(json)
    end

    test "missing optional keys default to empty strings" do
      json = %{"number" => 1}

      assert GitHub.decode_pr_for_test(json) == %{
               number: 1,
               base_ref: "",
               head_ref: "",
               title: "",
               body: "",
               url: ""
             }
    end

    test "null optional values become empty strings" do
      json = %{
        "number" => 1,
        "baseRefName" => nil,
        "title" => nil,
        "body" => nil,
        "url" => nil
      }

      assert %{base_ref: "", title: "", body: "", url: ""} = GitHub.decode_pr_for_test(json)
    end

    test "raises KeyError when `number` is missing — caller must rescue" do
      # `current_pr/1`'s rescue clause catches this and surfaces an
      # "unexpected JSON shape" warning instead of swallowing it as
      # a generic error.
      assert_raise KeyError, fn ->
        GitHub.decode_pr_for_test(%{"baseRefName" => "main"})
      end
    end
  end
end
