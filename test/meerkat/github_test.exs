defmodule Meerkat.GitHubTest do
  # `current_pr/1` tests put a gh stub on the process-wide PATH.
  use Meerkat.Case, async: false

  import ExUnit.CaptureIO

  import Meerkat.TestHelpers,
    only: [git: 2, import_commits: 2, put_env: 2, read_tree: 3, stub_git: 1]

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

  # Puts a gh stub first on PATH. It records its arguments, and answers
  # like gh for a branch with a PR.
  defp gh_on_path(_context) do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-github")
    on_exit(fn -> File.rm_rf!(dir) end)

    bin = Path.join(dir, "gh-bin")
    calls = Path.join(dir, "gh-calls")
    File.mkdir_p!(bin)

    gh(bin, """
    echo "$*" >> '#{calls}'
    echo '{"number": 7, "headRefName": "feature/x"}'
    """)

    put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

    {:ok, dir: dir, bin: bin, calls: calls}
  end

  # Jason's message for the `not json` the stubs print.
  @not_json_error ~s[unexpected byte at position 0: 0x6E ("n")]

  defp gh(bin, script) do
    File.write!(Path.join(bin, "gh"), "#!/bin/sh\n" <> script)
    File.chmod!(Path.join(bin, "gh"), 0o755)
  end

  # A PATH holding no gh; git is stubbed, so the tests start none.
  defp without_gh(dir) do
    empty = Path.join(dir, "empty-bin")
    File.mkdir_p!(empty)
    put_env("PATH", empty)
  end

  describe "view/2" do
    setup :gh_on_path

    test "asks gh for the PR's fields and decodes them", %{dir: dir, calls: calls} do
      assert {:ok, %{number: 7, head_ref: "feature/x", base_ref: ""}} = GitHub.view(dir, "12")

      assert File.read!(calls) ==
               "pr view 12 --json number,baseRefName,headRefName,title,body,url\n"
    end

    test "reports output gh exited 0 with that is not JSON", %{dir: dir, bin: bin} do
      gh(bin, "echo 'not json'\n")

      assert GitHub.view(dir, "12") ==
               {:error, "could not parse `gh pr view` JSON: #{@not_json_error}"}
    end

    test "reports gh's exit status and trimmed output", %{dir: dir, bin: bin} do
      gh(bin, "echo '  no such PR  ' >&2\nexit 3\n")

      assert GitHub.view(dir, "12") == {:error, "gh pr view 12 exited 3: no such PR"}
    end
  end

  describe "current_pr/1" do
    setup :gh_on_path

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

    test "a shell that cannot find gh means no PR and no warning", %{dir: dir, bin: bin} do
      head(:branch, "feature/x")
      gh(bin, "echo 'sh: gh: command not found'\nexit 127\n")

      assert capture_io(:stderr, fn -> assert GitHub.current_pr(dir) == nil end) == ""
    end

    test "any other gh failure means no PR, with a warning", %{dir: dir, bin: bin} do
      head(:branch, "feature/x")
      gh(bin, "echo ' HTTP 502 ' >&2\nexit 1\n")

      assert capture_io(:stderr, fn -> assert GitHub.current_pr(dir) == nil end) ==
               "meerkat: warning — gh pr view failed: HTTP 502\n"
    end

    test "output gh exited 0 with that is not JSON means no PR, with a warning",
         %{dir: dir, bin: bin} do
      head(:branch, "feature/x")
      gh(bin, "echo 'not json'\n")

      assert capture_io(:stderr, fn -> assert GitHub.current_pr(dir) == nil end) ==
               "meerkat: warning — gh pr view returned non-JSON on success: #{@not_json_error}\n"
    end

    for {label, json} <- [
          {"no number", ~s({"url":"u"})},
          {"a number that is not numeric", ~s({"number":"x"})},
          {"a fractional number", ~s({"number":1.5})},
          {"a list for the PR", "[]"},
          {"null for the PR", "null"}
        ] do
      test "a PR with #{label} means no PR, warning of an unexpected shape",
           %{dir: dir, bin: bin} do
        head(:branch, "feature/x")
        gh(bin, "echo '#{unquote(json)}'\n")

        reason =
          try do
            GitHub.decode_pr_for_test(Jason.decode!(unquote(json)))
          rescue
            e -> Exception.message(e)
          end

        assert capture_io(:stderr, fn -> assert GitHub.current_pr(dir) == nil end) ==
                 "meerkat: warning — gh pr view returned an unexpected JSON shape: #{reason}\n"
      end
    end

    test "gh missing from PATH means no PR, with a warning", %{dir: dir} do
      head(:branch, "feature/x")
      without_gh(dir)

      assert capture_io(:stderr, fn -> assert GitHub.current_pr(dir) == nil end) ==
               "meerkat: warning — gh pr view: gh not on PATH (Erlang error: :enoent)\n"
    end
  end

  describe "post_review/3" do
    setup :gh_on_path

    @payload %{body: "Looks good", event: "COMMENT", comments: [%{path: "a.txt", line: 1}]}

    test "posts the payload as a review on the PR and returns its URL",
         %{dir: dir, bin: bin, calls: calls} do
      # Records its arguments, then the --input file's content.
      gh(bin, """
      echo "$*" >> '#{calls}'
      cat "$6" >> '#{calls}'
      echo '{"html_url": "https://github.com/o/r/pull/9#review-1"}'
      """)

      assert GitHub.post_review(dir, 9, @payload) ==
               {:ok, "https://github.com/o/r/pull/9#review-1"}

      [args, body] = String.split(File.read!(calls), "\n", parts: 2)

      assert [_, tmp] =
               Regex.run(
                 ~r"\Aapi -X POST /repos/{owner}/{repo}/pulls/9/reviews --input (\S+)\z",
                 args
               )

      assert Jason.decode!(body) == Jason.decode!(Jason.encode!(@payload))
      refute File.exists?(tmp)
    end

    test "reports gh's exit status and trimmed output", %{dir: dir, bin: bin} do
      gh(bin, "echo ' HTTP 422 ' >&2\nexit 1\n")

      assert GitHub.post_review(dir, 9, @payload) == {:error, "gh api exited 1: HTTP 422"}
    end

    for {shape, json} <- [{"no html_url", "{}"}, {"a non-string html_url", ~s({"html_url": 5})}] do
      test "reports a response with #{shape}", %{dir: dir, bin: bin} do
        gh(bin, "echo '#{unquote(json)}'\n")

        assert GitHub.post_review(dir, 9, @payload) ==
                 {:error, "gh api response missing html_url: #{unquote(json)}\n"}
      end
    end

    test "reports a response that is not JSON", %{dir: dir, bin: bin} do
      gh(bin, "echo 'not json'\n")

      assert GitHub.post_review(dir, 9, @payload) ==
               {:error, "could not parse gh api response: #{@not_json_error}"}
    end

    test "reports gh missing from PATH", %{dir: dir} do
      without_gh(dir)

      assert GitHub.post_review(dir, 9, @payload) == {:error, "gh binary not found on PATH"}
    end

    test "reports a request body it cannot write, without calling gh",
         %{dir: dir, calls: calls} do
      # Writable but not searchable: the tmp dir is accepted, yet no file
      # can be created in it.
      tmp_dir = Path.join(dir, "tmp")
      File.mkdir_p!(tmp_dir)
      File.chmod!(tmp_dir, 0o200)
      on_exit(fn -> File.chmod(tmp_dir, 0o755) end)
      put_env("TMPDIR", tmp_dir)

      assert {:error, message} = GitHub.post_review(dir, 9, @payload)

      assert message =~
               ~r"\Acouldn't stage gh request body at #{Regex.escape(tmp_dir)}/meerkat-gh-\S+\.json: :eacces\z"

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

    test "a number that is neither an integer nor a string has no decoding" do
      assert_raise FunctionClauseError, fn -> GitHub.decode_pr_for_test(%{"number" => 1.5}) end
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
