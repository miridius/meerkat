defmodule Meerkat.GitHubTest do
  # `current_pr/1` tests put a gh stub on the process-wide PATH.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Meerkat.TestHelpers, only: [git: 2]

  # decode_pr/1 is private; we exercise it through the public-but-
  # internal `decode_pr_for_test/1` exposed at the bottom of the
  # module so tests don't have to set up the gh stub for the
  # serialisation path.
  alias Meerkat.GitHub

  describe "current_pr/1" do
    setup do
      Meerkat.TestHelpers.isolate_git_config()
      dir = Meerkat.TestHelpers.make_git_repo("meerkat-github")
      git(dir, ["config", "user.name", "t"])
      git(dir, ["config", "user.email", "t@t.t"])
      git(dir, ["switch", "-q", "-c", "feature/x"])
      git(dir, ["commit", "--allow-empty", "-qm", "base"])

      # The stub records its arguments, and answers like gh for a
      # branch with a PR.
      bin = Path.join(dir, "gh-bin")
      calls = Path.join(dir, "gh-calls")
      File.mkdir_p!(bin)

      File.write!(Path.join(bin, "gh"), """
      #!/bin/sh
      echo "$*" >> '#{calls}'
      echo '{"number": 7, "headRefName": "feature/x"}'
      """)

      File.chmod!(Path.join(bin, "gh"), 0o755)
      old_path = System.fetch_env!("PATH")
      System.put_env("PATH", bin <> ":" <> old_path)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(dir)
      end)

      {:ok, dir: dir, bin: bin, calls: calls}
    end

    test "on a branch, gh resolves the current branch itself", %{dir: dir, calls: calls} do
      assert %{number: 7} = GitHub.current_pr(dir)
      assert File.read!(calls) =~ ~r/^pr view --json /
    end

    test "mid-rebase, gh is asked for the branch being rebased", %{dir: dir, calls: calls} do
      git(dir, [
        "-c",
        "sequence.editor=sed -i.bak -e '1s/^pick/edit/'",
        "rebase",
        "-q",
        "-i",
        "--root"
      ])

      assert %{number: 7} = GitHub.current_pr(dir)
      assert File.read!(calls) =~ ~r/^pr view feature\/x --json /
    end

    test "mid-rebase, a branch whose PR comes from a fork has no PR and no warning",
         %{dir: dir, bin: bin, calls: calls} do
      # A bare branch name matches only same-repo PRs, so gh answers
      # this way for a branch whose PR's head lives on a fork.
      File.write!(Path.join(bin, "gh"), """
      #!/bin/sh
      echo "$*" >> '#{calls}'
      echo 'no pull requests found for branch "feature/x"' >&2
      exit 1
      """)

      git(dir, [
        "-c",
        "sequence.editor=sed -i.bak -e '1s/^pick/edit/'",
        "rebase",
        "-q",
        "-i",
        "--root"
      ])

      assert capture_io(:stderr, fn -> assert GitHub.current_pr(dir) == nil end) == ""
      assert File.read!(calls) =~ ~r/^pr view feature\/x --json /
    end

    test "mid-rebase, a branch gh would read as a PR number is not looked up",
         %{dir: dir, calls: calls} do
      for branch <- ["28", "#28", "+28"] do
        git(dir, ["switch", "-q", "-c", branch, "feature/x"])

        git(dir, [
          "-c",
          "sequence.editor=sed -i.bak -e '1s/^pick/edit/'",
          "rebase",
          "-q",
          "-i",
          "--root"
        ])

        assert Meerkat.Git.head_branch(dir) == {:rebasing, branch}
        assert GitHub.current_pr(dir) == nil
        git(dir, ["rebase", "--abort"])
      end

      refute File.exists?(calls)
    end

    test "a detached HEAD outside a rebase skips the lookup without a warning",
         %{dir: dir, calls: calls} do
      git(dir, ["checkout", "-q", "--detach"])

      assert capture_io(:stderr, fn -> assert GitHub.current_pr(dir) == nil end) == ""
      refute File.exists?(calls)
    end
  end

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
