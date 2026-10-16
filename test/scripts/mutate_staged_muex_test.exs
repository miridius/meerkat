defmodule Meerkat.MutateStagedMuexTest do
  # Runs the pinned muex's `mix muex` task, in this VM, with the flags
  # scripts/mutate.sh staged gives it, in a throwaway project. Its refusal
  # raises, and test/scripts/pre_commit_test.exs shows a failed muex run
  # blocks the commit. It changes directory and the OS environment, so it is
  # synchronous.
  use Meerkat.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Muex, as: MuexTask
  import Meerkat.TestHelpers, only: [git: 2, stage: 3]

  setup do
    # As scripts/mutate.sh does before it runs muex, so a run from a hook
    # does not read meerkat's own index.
    {vars, 0} = System.cmd("git", ["rev-parse", "--local-env-vars"])
    for var <- String.split(vars), do: Meerkat.TestHelpers.put_env(var, nil)

    dir = Meerkat.TestHelpers.make_git_repo("meerkat-mutate-staged")
    on_exit(fn -> File.rm_rf!(dir) end)
    git(dir, ["config", "user.email", "t@t.t"])
    git(dir, ["config", "user.name", "t"])
    File.write!(Path.join(dir, "mix.exs"), "")
    {:ok, dir: dir}
  end

  # Deleting the comment moves double/1 up a line on disk, off the line the
  # index numbers as staged, so the run would find no mutant to test.
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

  # scripts/mutate.sh's run_mutate, but on one job.
  defp gate_args(dir) do
    ~w(--files lib/tiny.ex --coverage-guided --concurrency 1 --no-filter --no-optimize
       --staged --fail-at 0 --format json --output) ++ [Path.join(dir, "_build/report.json")]
  end
end
