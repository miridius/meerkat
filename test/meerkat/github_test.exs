defmodule Meerkat.GitHubTest do
  # `current_pr/1` tests put a gh stub on the process-wide PATH.
  use Meerkat.Case, async: false

  import ExUnit.CaptureIO
  import Meerkat.TestHelpers, only: [git: 2, import_commits: 2, read_tree: 3, stub_git: 1]

  # decode_pr/1 is private; we exercise it through the public-but-
  # internal `decode_pr_for_test/1` exposed at the bottom of the
  # module so tests don't have to set up the gh stub for the
  # serialisation path.
  alias Meerkat.GitHub

  # A repo built once, on feature/x with a.txt staged; tests only read it.
  setup_all do
    template =
      Meerkat.TestHelpers.fixture_template("meerkat-github", fn dir ->
        git(dir, ["init", "-q", "--initial-branch=feature/x"])

        import_commits(dir, [
          {"refs/heads/feature/x", %{"a.txt" => "base\n"}},
          {"refs/meerkat-test/staged", %{"a.txt" => "staged mid-rebase\n"}}
        ])

        read_tree(dir, "refs/meerkat-test/staged", nil)
      end)

    {:ok, repo: template}
  end

  # Has git show HEAD on the branch `name`, or detached, mid-rebase of
  # `branch` when given: every `rev-parse --path-format=absolute` then
  # names `head-name`. Git's own rebase states are Meerkat.Git's tests'.
  defp head(:detached, dir, branch) do
    head_name = Path.join(dir, "head-name")
    if branch, do: File.write!(head_name, "refs/heads/#{branch}\n")

    stub_git(fn
      [_git, "symbolic-ref" | _] -> {"", 1}
      [_git, "rev-parse", "--path-format=absolute" | _] -> {head_name <> "\n", 0}
      _argv -> :real
    end)
  end

  defp head(:branch, name) do
    stub_git(fn
      [_git, "symbolic-ref" | _] -> {name <> "\n", 0}
      _argv -> :real
    end)
  end

  describe "current_pr/1" do
    setup do
      dir = Meerkat.TestHelpers.tmp_path("meerkat-github")
      on_exit(fn -> File.rm_rf!(dir) end)

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

      on_exit(fn -> System.put_env("PATH", old_path) end)

      {:ok, dir: dir, bin: bin, calls: calls}
    end

    test "on a branch, gh resolves the current branch itself", %{dir: dir, calls: calls} do
      head(:branch, "feature/x")

      assert %{number: 7} = GitHub.current_pr(dir)
      assert File.read!(calls) =~ ~r/^pr view --json /
    end

    test "mid-rebase, gh is asked for the branch being rebased", %{dir: dir, calls: calls} do
      head(:detached, dir, "feature/x")

      assert %{number: 7} = GitHub.current_pr(dir)
      assert File.read!(calls) =~ ~r/^pr view feature\/x --json /
    end

    test "a commit staged mid-rebase is reviewed on the rebased branch and its PR, without a warning",
         %{dir: dir, bin: bin, repo: repo} do
      # Like gh, which cannot tell the current branch while HEAD is detached.
      File.write!(Path.join(bin, "gh"), """
      #!/bin/sh
      if [ "$1 $2 $3" = "pr view feature/x" ]; then
        echo '{"number": 7, "baseRefName": "main", "headRefName": "feature/x", "url": "u"}'
        exit 0
      fi
      echo 'could not determine current branch: failed to run git: not on any branch' >&2
      exit 1
      """)

      head(:detached, dir, "feature/x")

      stderr =
        capture_io(:stderr, fn ->
          assert {:ok, state} = Meerkat.ReviewState.from_target({:staged, nil}, repo)
          assert %{number: 7} = state.pr
          assert state.head_branch == "feature/x"
          assert state.base_branch == "main"
          assert [%{file_name: "a.txt", new_content: "staged mid-rebase\n"}] = state.files
        end)

      assert stderr == ""
    end

    test "a branch with no PR has no PR and no warning", %{dir: dir, bin: bin, calls: calls} do
      head(:branch, "feature/x")

      # As gh answers for a branch it finds no PR for.
      File.write!(Path.join(bin, "gh"), """
      #!/bin/sh
      echo "$*" >> '#{calls}'
      echo 'no pull requests found for branch "feature/x"' >&2
      exit 1
      """)

      assert capture_io(:stderr, fn -> assert GitHub.current_pr(dir) == nil end) == ""
      assert File.read!(calls) =~ ~r/^pr view --json /
    end

    test "a detached HEAD outside a rebase skips the lookup without a warning",
         %{dir: dir, calls: calls} do
      head(:detached, dir, nil)

      assert capture_io(:stderr, fn -> assert GitHub.current_pr(dir) == nil end) == ""
      refute File.exists?(calls)
    end
  end

  describe "pr_selector/1" do
    test "a checked-out branch lets gh resolve it" do
      assert GitHub.pr_selector({:checked_out, "feature/x"}) == {:ok, []}
    end

    test "mid-rebase, the branch being rebased is named, digits and all" do
      for branch <- ["feature/x", "28-fix", "fix-28", "#28x"],
          do: assert(GitHub.pr_selector({:rebasing, branch}) == {:ok, [branch]})
    end

    test "mid-rebase, a branch gh would read as a PR number is not looked up" do
      for branch <- ["28", "#28", "+28", "-28"],
          do: assert(GitHub.pr_selector({:rebasing, branch}) == :none)
    end

    test "a detached HEAD is not looked up" do
      assert GitHub.pr_selector(:detached) == :none
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
