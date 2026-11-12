defmodule Meerkat.OutdatedGateTest do
  # The seam between scripts/outdated.ts and the tools it runs: the real
  # script, run by bun, against stubs for mix, pnpm, curl, gh and bun on
  # PATH. scripts/outdated.test.ts covers the gate's logic.
  use ExUnit.Case, async: true

  @root File.cwd!()
  @bun System.find_executable("bun")

  @lock """
  %{
    "mdex": {:hex, :mdex, "0.14.1", "abc", [:mix], [], "hexpm", "def"},
    "muex": {:git, "https://github.com/someone/muex.git", "a628d48", [ref: "a628d48"]},
  }
  """

  @hex_report """
  Dependency  Only  Current  Latest  Status
  jason  1.4.3  1.4.5  Update possible
  plug  1.20.3  2.1.1  Update not possible
  """

  test "the gate reads each tool's report and blocks the push on what is behind" do
    base = Meerkat.TestHelpers.tmp_path("meerkat-outdated")
    on_exit(fn -> File.rm_rf!(base) end)
    stubs = Path.join(base, "stubs")
    log = Path.join(base, "log")
    File.mkdir_p!(Path.join(base, "scripts"))
    File.mkdir_p!(Path.join(base, "assets"))
    File.mkdir_p!(stubs)

    for script <- ~w(outdated.ts deps-common.ts) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([base, "scripts", script]))
    end

    for file <- ~w(package.json pnpm-workspace.yaml pnpm-lock.yaml assets/package.json),
        do: File.write!(Path.join(base, file), "base\n")

    File.write!(Path.join(base, "mix.lock"), @lock)

    File.write!(
      Path.join(base, "scripts/dep-exemptions.json"),
      ~s({"jason": {"version": "1.4.5", "reason": "x"}})
    )

    young = DateTime.utc_now() |> DateTime.add(-12, :hour) |> DateTime.to_iso8601()
    old = "2020-01-01T00:00:00.000000Z"

    hex_record = fn version, at ->
      Jason.encode!(%{
        "releases" => [%{"version" => version, "inserted_at" => at}],
        "meta" => %{"links" => %{"GitHub" => "https://github.com/upstream/muex"}}
      })
    end

    File.write!(Path.join(base, "plug.json"), hex_record.("2.1.1", young))
    File.write!(Path.join(base, "muex.json"), hex_record.("0.11.2", old))

    # Each stub logs its command line with the cwd, GIT_INDEX_FILE and, for
    # curl, its stdin.
    File.write!(Path.join(stubs, "stub"), """
    #!/usr/bin/env bash
    cmd="$(basename "$0") $*"
    stdin=""
    if [[ "$cmd" == "curl "*" -K - "* ]]; then stdin=$(cat); fi
    echo "$cmd | ${PWD##*/} | ${GIT_INDEX_FILE-unset} | $stdin" >> '#{log}'
    case "$cmd" in
      "mix hex.outdated") printf '%s' '#{@hex_report}'; exit 1 ;;
      "pnpm -r outdated --format json --config.minimum-release-age=0")
        echo ' WARN  deprecated subdependency' >&2
        echo '{"vite": {"current": "8.2.0", "latest": "8.3.2"}}'; exit 1 ;;
      "pnpm -r outdated --format json") echo '{"vite": {"current": "8.2.0", "latest": "8.3.1"}}'; exit 1 ;;
      "pnpm -r update --latest --lockfile-only --ignore-scripts vite")
        [[ -f pnpm-workspace.yaml && -f assets/package.json && -L deps ]] || exit 3 ;;
      "curl -sSf --max-time 10 https://hex.pm/api/packages/"*)
        cat '#{base}'/"${cmd##*/}.json" ;;
      "curl -sSL "*"/compare/v0.11.2...someone:muex:a628d48")
        printf '{"status": "behind"}\\n200' ;;
      "gh auth token") echo gh-t0k ;;
      "bun scripts/toolchain.ts check") echo "toolchain checked" ;;
    esac
    """)

    File.chmod!(Path.join(stubs, "stub"), 0o755)
    for tool <- ~w(mix pnpm curl gh bun), do: File.ln_s!("stub", Path.join(stubs, tool))

    assert {out, 1} =
             System.cmd(@bun, [Path.join(base, "scripts/outdated.ts")],
               cd: @root,
               env: [
                 {"PATH", stubs <> ":" <> System.fetch_env!("PATH")},
                 {"GITHUB_TOKEN", nil},
                 {"GIT_INDEX_FILE", "/nonexistent/index"}
               ],
               stderr_to_stdout: true
             )

    refute out =~ "WARN  deprecated subdependency"
    assert out =~ "BLOCKED: vite is outdated (latest: 8.3.1)"
    refute out =~ "stale exemption"
    assert out =~ "exempt: jason@1.4.5 (x)"
    assert out =~ "too young: plug@2.1.1 is under the 24h Hex cooldown"

    assert out =~
             "BLOCKED: muex is pinned to a628d48, which does not contain upstream/muex v0.11.2"

    assert out =~ "=== toolchain ===\ntoolchain checked\n"
    assert out =~ "scripts/outdated.ts: dependencies are behind latest"

    ran = log |> File.read!() |> String.split("\n", trim: true)
    base_name = Path.basename(base)

    # It ran from the repo root its own path names, syncing without the
    # index Git exports to hooks, and checked vite on a scratch copy.
    assert Enum.take(ran, 4) == [
             "curl -sf --max-time 5 https://registry.npmjs.org | #{base_name} | /nonexistent/index | ",
             "curl -sf --max-time 5 https://hex.pm | #{base_name} | /nonexistent/index | ",
             "mix deps.get --check-locked | #{base_name} | unset | ",
             "pnpm install --frozen-lockfile --ignore-scripts --prefer-offline | #{base_name} | unset | "
           ]

    assert [scratch] = for(line <- ran, line =~ "--lockfile-only", do: line)
    assert [_, dir, _, _] = String.split(scratch, " | ")
    assert dir =~ "meerkat-pnpm-"
    refute File.exists?(Path.join(System.tmp_dir!(), dir))

    # gh's token went to curl on stdin, kept out of the process list.
    assert Enum.any?(
             ran,
             &(&1 =~ ~s(/compare/v0.11.2...someone:muex:a628d48 | ) and
                 &1 =~ ~s(header = "Authorization: Bearer gh-t0k"))
           )

    assert "bun scripts/age-excludes.ts check | #{base_name} | /nonexistent/index | " in ran
  end
end
