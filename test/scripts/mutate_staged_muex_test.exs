defmodule Meerkat.MutateStagedMuexTest do
  # Runs the pinned muex's `mix muex` task, in this VM, with the flags
  # scripts/mutate.sh staged gives it, in a throwaway project. Its refusal
  # raises, and test/scripts/pre_commit_test.exs shows a failed muex run
  # blocks the commit. It changes directory and the OS environment, so it is
  # synchronous.
  use Meerkat.Case, async: false

  import ExUnit.CaptureIO
  import Meerkat.TestHelpers, only: [git: 2, make_git_repo: 1, put_env: 2, stage: 3]

  alias Mix.Tasks.Muex, as: MuexTask

  setup do
    # Git's hook variables, cleared so that a test run from a hook does not
    # point muex at meerkat's own index.
    {vars, 0} = System.cmd("git", ["rev-parse", "--local-env-vars"])
    for var <- String.split(vars), do: put_env(var, nil)

    dir = make_git_repo("meerkat-mutate-staged")
    on_exit(fn -> File.rm_rf!(dir) end)
    git(dir, ["config", "user.email", "t@t.t"])
    git(dir, ["config", "user.name", "t"])
    File.write!(Path.join(dir, "mix.exs"), "")
    {:ok, dir: dir}
  end

  # Without the refusal, the run would find no mutant to test: deleting the
  # comment moves double/1 up a line on disk, off the line the index numbers
  # as staged.
  test "a staged file whose only unstaged change is a deletion is refused", %{dir: dir} do
    stage(dir, "lib/tiny.ex", tiny("  # note\n", "a * 2"))
    git(dir, ["commit", "-qm", "base"])
    stage(dir, "lib/tiny.ex", tiny("  # note\n", "a * 3"))
    File.write!(Path.join(dir, "lib/tiny.ex"), tiny("", "a * 3"))

    error =
      assert_raise Mix.Error, fn ->
        File.cd!(dir, fn -> capture_io(fn -> MuexTask.run(gate_args(dir)) end) end)
      end

    assert error.message =~ "unstaged changes on top of their staged ones"
    assert error.message =~ "lib/tiny.ex"
  end

  defp tiny(comment, body) do
    "defmodule Tiny do\n#{comment}  def double(a), do: #{body}\nend\n"
  end

  # scripts/mutate.sh's run_mutate flags, with one test BEAM and only
  # lib/tiny.ex.
  defp gate_args(dir) do
    ~w(--files lib/tiny.ex --test-paths test/tiny_test.exs --coverage-guided --concurrency 1 --no-filter --no-optimize
       --staged --fail-at 0 --format json --output) ++ [Path.join(dir, "_build/report.json")]
  end
end
