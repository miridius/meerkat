defmodule Meerkat.AgeExcludesTest do
  # Runs the repo's real scripts/age-excludes.ts in a scratch workspace,
  # with a pnpm stub on PATH whose `pnpm view NAME time --json` prints the
  # publish times each test wrote for NAME.
  use ExUnit.Case, async: true

  @script Path.join(File.cwd!(), "scripts/age-excludes.ts")

  @workspace "packages:\n  - assets\nminimumReleaseAge: 1440\n"

  @block "\n# Releases under 24h old taken to fix an advisory; scripts/age-excludes.ts\n" <>
           "# drops each once it is 24h old.\nminimumReleaseAgeExclude:\n"

  @old "2020-01-01T00:00:00.000Z"

  setup do
    base = Meerkat.TestHelpers.tmp_path("meerkat-age-excludes")
    on_exit(fn -> File.rm_rf!(base) end)

    work = Path.join(base, "work")
    times = Path.join(base, "times")
    stubs = Path.join(base, "stubs")
    for dir <- [work, times, stubs], do: File.mkdir_p!(dir)

    File.write!(Path.join(stubs, "pnpm"), """
    #!/usr/bin/env bash
    [[ "$1 $3 $4" == "view time --json" ]] || exit 1
    cat '#{times}'/"$(printf %s "$2" | tr / _)"
    """)

    File.chmod!(Path.join(stubs, "pnpm"), 0o755)

    time(times, "vite", %{"8.3.2" => hours_ago(2), "8.3.1" => @old})
    time(times, "@esbuild/darwin-arm64", %{"0.30.1" => @old})

    %{work: work, times: times, path: stubs <> ":" <> System.fetch_env!("PATH")}
  end

  defp excluding(ctx, entries) do
    list = Enum.map_join(entries, &~s(  - "#{&1}"\n))
    File.write!(Path.join(ctx.work, "pnpm-workspace.yaml"), @workspace <> @block <> list)
  end

  test "prune drops the entries 24h old and keeps the young ones", ctx do
    excluding(ctx, ["@esbuild/darwin-arm64@0.30.1", "vite@8.3.2"])

    assert {out, 0} = run(ctx, "prune")
    assert out =~ "pre-commit: @esbuild/darwin-arm64@0.30.1 is 24h old; dropped"
    assert workspace(ctx) == @workspace <> @block <> ~s(  - "vite@8.3.2"\n)
  end

  test "prune drops the list with its last entry", ctx do
    excluding(ctx, ["@esbuild/darwin-arm64@0.30.1", "vite@8.3.1"])

    assert {_, 0} = run(ctx, "prune")
    assert workspace(ctx) == @workspace
  end

  test "check fails the gate on an entry 24h old", ctx do
    excluding(ctx, ["vite@8.3.1", "vite@8.3.2"])

    assert {out, 1} = run(ctx, "check")

    assert out =~
             "BLOCKED: pnpm-workspace.yaml excludes vite@8.3.1 from minimumReleaseAge, but it is 24h old"

    refute out =~ "vite@8.3.2"
  end

  test "check passes young entries and no list", ctx do
    excluding(ctx, ["vite@8.3.2"])
    assert {"", 0} = run(ctx, "check")

    File.write!(Path.join(ctx.work, "pnpm-workspace.yaml"), @workspace)
    assert {"", 0} = run(ctx, "check")
  end

  test "an unreadable publish time fails closed", ctx do
    excluding(ctx, ["vite@9.0.0"])

    for mode <- ~w(check prune) do
      assert {out, 2} = run(ctx, mode)
      assert out =~ "could not read when the registry published vite@9.0.0"
    end

    assert workspace(ctx) == @workspace <> @block <> ~s(  - "vite@9.0.0"\n)
  end

  defp hours_ago(h),
    do: DateTime.utc_now() |> DateTime.add(-h, :hour) |> DateTime.to_iso8601()

  defp time(times, name, versions),
    do: File.write!(Path.join(times, String.replace(name, "/", "_")), Jason.encode!(versions))

  defp workspace(ctx), do: File.read!(Path.join(ctx.work, "pnpm-workspace.yaml"))

  defp run(ctx, mode) do
    System.cmd("bun", [@script, mode],
      cd: ctx.work,
      env: [{"PATH", ctx.path}],
      stderr_to_stdout: true
    )
  end
end
