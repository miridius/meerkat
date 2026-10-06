defmodule Meerkat.SetupWorktreeHookTest do
  # Runs .claude/hooks/setup-worktree.sh against a temp checkout, with stub
  # `mix` and `pnpm` on PATH that record each call, sleep a chosen time
  # and exit with a chosen status.
  use ExUnit.Case, async: true

  @script Path.expand(".claude/hooks/setup-worktree.sh")

  # A hook-exported GIT_DIR would point git at meerkat's own repo.
  @unset_git Enum.map(~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE), &{&1, nil})

  @lock """
  %{
    "bandit": {:hex, :bandit, "1.12.5", "x", [:mix], [], "hexpm", "y"},
    "muex": {:git, "https://example.com/muex.git", "abc", [ref: "abc"]},
  }
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "meerkat-setup-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    checkout = Path.join(dir, "checkout")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    {_, 0} = System.cmd("git", ["init", "-q", checkout], env: @unset_git)
    File.write!(Path.join(checkout, "mix.lock"), @lock)
    File.write!(Path.join(checkout, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n")

    # A successful stub leaves behind what the real install would.
    installs = %{
      "mix" => "mkdir -p deps/bandit deps/muex/.git",
      "pnpm" => "mkdir -p node_modules && touch node_modules/.modules.yaml"
    }

    for {tool, install} <- installs do
      stub = Path.join(bin, tool)

      File.write!(stub, """
      #!/usr/bin/env bash
      echo "#{tool} $*" >> '#{dir}/calls'
      echo "#{tool} output"
      sleep "$(cat '#{dir}/#{tool}-sleep' 2>/dev/null || echo 0)"
      status=$(cat '#{dir}/#{tool}-status' 2>/dev/null || echo 0)
      if [ "$status" = 0 ]; then #{install}; fi
      exit "$status"
      """)

      File.chmod!(stub, 0o755)
    end

    {:ok, dir: dir, checkout: checkout}
  end

  defp set_up(checkout) do
    File.mkdir_p!(Path.join([checkout, "deps", "bandit"]))
    File.mkdir_p!(Path.join([checkout, "deps", "muex", ".git"]))
    File.mkdir_p!(Path.join(checkout, "node_modules"))
    File.write!(Path.join([checkout, "node_modules", ".modules.yaml"]), "")
  end

  defp run_hook(dir, cwd) do
    input = JSON.encode!(%{hook_event_name: "SubagentStart", cwd: cwd})
    path = Path.join(dir, "bin") <> ":" <> System.get_env("PATH")

    System.cmd("bash", ["-c", ~s(printf '%s' "$1" | "$2"), "_", input, @script],
      env: [{"PATH", path} | @unset_git],
      stderr_to_stdout: true
    )
  end

  defp calls(dir) do
    case File.read(Path.join(dir, "calls")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  test "a checkout with its deps installed runs nothing and prints nothing", ctx do
    set_up(ctx.checkout)

    assert run_hook(ctx.dir, ctx.checkout) == {"", 0}
    assert calls(ctx.dir) == []
  end

  test "a checkout with no deps installs both", ctx do
    assert run_hook(ctx.dir, ctx.checkout) == {"", 0}

    assert calls(ctx.dir) == [
             "mix deps.get",
             "pnpm install --frozen-lockfile --prefer-offline"
           ]
  end

  test "a git dep without its nested repo fetches Mix deps", ctx do
    set_up(ctx.checkout)
    File.rm_rf!(Path.join([ctx.checkout, "deps", "muex", ".git"]))

    assert run_hook(ctx.dir, ctx.checkout) == {"", 0}
    assert calls(ctx.dir) == ["mix deps.get"]
  end

  test "node_modules without pnpm's state installs JS deps", ctx do
    set_up(ctx.checkout)
    File.rm!(Path.join([ctx.checkout, "node_modules", ".modules.yaml"]))

    assert run_hook(ctx.dir, ctx.checkout) == {"", 0}
    assert calls(ctx.dir) == ["pnpm install --frozen-lockfile --prefer-offline"]
  end

  test "hooks starting at once in one checkout install only once", ctx do
    File.write!(Path.join(ctx.dir, "mix-sleep"), "1")

    results =
      1..3
      |> Enum.map(fn _ -> Task.async(fn -> run_hook(ctx.dir, ctx.checkout) end) end)
      |> Task.await_many(60_000)

    assert results == List.duplicate({"", 0}, 3)

    assert calls(ctx.dir) == [
             "mix deps.get",
             "pnpm install --frozen-lockfile --prefer-offline"
           ]
  end

  test "a failed install is reported to Claude without blocking", ctx do
    File.write!(Path.join(ctx.dir, "mix-status"), "1")

    assert {out, 0} = run_hook(ctx.dir, ctx.checkout)

    assert %{
             "hookSpecificOutput" => %{
               "hookEventName" => "SubagentStart",
               "additionalContext" => context
             }
           } = JSON.decode!(out)

    assert context =~ "`mix deps.get` failed in #{ctx.checkout}:\nmix output"
    refute context =~ "pnpm"
  end

  test "a directory that is not a meerkat checkout is left alone", ctx do
    other = Path.join(ctx.dir, "other")
    File.mkdir_p!(other)

    assert run_hook(ctx.dir, other) == {"", 0}
    assert calls(ctx.dir) == []
  end
end
