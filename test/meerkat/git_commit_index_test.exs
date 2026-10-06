defmodule Meerkat.GitCommitIndexTest do
  # Real `git commit`s whose commit-msg hook runs `Meerkat.Git.staged_file_diffs/1`
  # in a fresh VM, as `meerkat --commit-msg` does. For `git commit -a` and
  # `git commit <path>`, git hands the hook the index holding what the commit
  # will contain in GIT_INDEX_FILE; the real index does not hold it. What the
  # hook reads must be what the commit records.
  use ExUnit.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, hook_env: 0, stage: 3]

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    dir = Meerkat.TestHelpers.make_git_repo("meerkat-commit-index")
    on_exit(fn -> File.rm_rf!(dir) end)

    git(dir, ["config", "user.email", "t@t.t"])
    git(dir, ["config", "user.name", "t"])
    for name <- ~w(a.txt b.txt c.txt), do: stage(dir, name, "base\n")
    git(dir, ["commit", "-qm", "base"])

    install_hook(Path.join(dir, ".git/hooks"))
    {:ok, dir: dir, report: Path.join(dir, ".git/reviewed")}
  end

  test "a plain commit is read from the real index", %{dir: dir} = ctx do
    stage(dir, "a.txt", "plain\n")

    commit(ctx, dir, ["-m", "plain"])

    assert_reviewed(ctx, dir, [{"a.txt", "plain\n"}])
    refute copied?(ctx)
  end

  test "`git commit -a` is read from the index holding every tracked change",
       %{dir: dir} = ctx do
    File.write!(Path.join(dir, "a.txt"), "all\n")
    stage(dir, "c.txt", "staged\n")

    commit(ctx, dir, ["-a", "-m", "all"])

    assert_reviewed(ctx, dir, [{"a.txt", "all\n"}, {"c.txt", "staged\n"}])
    assert copied?(ctx)
  end

  test "`git commit <path>` is read from the index holding only that path", %{dir: dir} = ctx do
    stage(dir, "a.txt", "left staged\n")
    File.write!(Path.join(dir, "b.txt"), "by path\n")

    commit(ctx, dir, ["b.txt", "-m", "path"])

    assert_reviewed(ctx, dir, [{"b.txt", "by path\n"}])
    assert copied?(ctx)
  end

  test "`git commit -a` in a linked worktree, where git also exports GIT_DIR",
       %{dir: dir} = ctx do
    linked = dir <> "-linked"
    on_exit(fn -> File.rm_rf!(linked) end)
    git(dir, ["worktree", "add", "-q", "-b", "linked", linked])
    File.write!(Path.join(linked, "a.txt"), "linked\n")

    commit(ctx, linked, ["-a", "-m", "linked"])

    assert_reviewed(ctx, linked, [{"a.txt", "linked\n"}])
    assert copied?(ctx)
  end

  test "a plain commit in a linked worktree is read from that worktree's own index",
       %{dir: dir} = ctx do
    linked = dir <> "-linked"
    on_exit(fn -> File.rm_rf!(linked) end)
    git(dir, ["worktree", "add", "-q", "-b", "linked", linked])
    stage(linked, "a.txt", "linked plain\n")

    commit(ctx, linked, ["-m", "linked plain"])

    assert_reviewed(ctx, linked, [{"a.txt", "linked plain\n"}])
    refute copied?(ctx)
  end

  defp install_hook(hooks) do
    hook = Path.join(hooks, "commit-msg")

    File.write!(hook, """
    #!/bin/sh
    exec elixir -pa '#{Mix.Project.compile_path()}' -e '
      held = System.fetch_env!("MEERKAT_REVIEWED") <> "-held"
      :ok = Meerkat.Git.hold_temporary_index(File.cwd!(), held)
      {:ok, files} = Meerkat.Git.staged_file_diffs(File.cwd!())
      report = for f <- files, do: {f.file_name, f.new_content, f.effective_oid}
      File.write!(System.fetch_env!("MEERKAT_REVIEWED"), :erlang.term_to_binary(report))
    '
    """)

    File.chmod!(hook, 0o755)
  end

  defp commit(ctx, dir, args) do
    {out, code} =
      System.cmd("git", ["commit", "-q" | args],
        cd: dir,
        env: [{"MEERKAT_REVIEWED", ctx.report} | hook_env()],
        stderr_to_stdout: true
      )

    assert code == 0, out
  end

  # The hook was shown `expected` as `{name, content}`, and each file's blob
  # is the one HEAD now records, with no other file in the commit.
  defp assert_reviewed(ctx, dir, expected) do
    shown = ctx.report |> File.read!() |> :erlang.binary_to_term()
    assert for({name, content, _} <- shown, do: {name, content}) == expected

    committed = git(dir, ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"])

    recorded =
      for name <- String.split(committed), do: {name, git(dir, ["rev-parse", "HEAD:" <> name])}

    assert for({name, _, oid} <- shown, do: {name, oid}) == recorded
  end

  # Whether the hook kept a copy of the index git named, as a detached review does.
  defp copied?(ctx), do: File.exists?(Path.join(ctx.report <> "-held", "index"))
end
