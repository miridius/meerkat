defmodule Meerkat.AdvisoryFixesTest do
  # Runs the repo's real scripts/advisory-fixes.ts in a scratch workspace.
  # pnpm and mix are replaced by a stub on PATH that logs each run: `pnpm
  # audit --json` and `mix hex.audit` print what each test wrote, `pnpm -r
  # update` refuses each version listed in `young` until
  # pnpm-workspace.yaml excludes it, and the frozen install refuses each
  # version listed in `locked-young` the same way.
  use ExUnit.Case, async: true

  @script Path.join(File.cwd!(), "scripts/advisory-fixes.ts")

  @workspace "packages:\n  - assets\nminimumReleaseAge: 1440\n"

  setup do
    base = Meerkat.TestHelpers.tmp_path("meerkat-advisory-fixes")
    on_exit(fn -> File.rm_rf!(base) end)

    work = Path.join(base, "work")
    stubs = Path.join(base, "stubs")
    File.mkdir_p!(Path.join(work, "assets"))
    File.mkdir_p!(stubs)

    File.write!(Path.join(work, "pnpm-workspace.yaml"), @workspace)
    File.write!(Path.join(work, "package.json"), ~s({"devDependencies": {"vite": "^8.0.0"}}))

    File.write!(
      Path.join(work, "assets/package.json"),
      ~s({"dependencies": {"svelte": "^5.0.0"}})
    )

    File.write!(Path.join(base, "audit.json"), ~s({"advisories": {}}))
    File.write!(Path.join(base, "hex-audit"), "No retired or vulnerable packages found.\n")
    File.write!(Path.join(base, "young"), "")
    File.write!(Path.join(base, "locked-young"), "")

    File.write!(Path.join(stubs, "stub"), """
    #!/usr/bin/env bash
    # refuse FILE: refuses, as pnpm 12 does, colour and line wrapping
    # included, each version FILE lists that pnpm-workspace.yaml does not
    # exclude.
    refuse() {
      local refused=() young
      while read -r young; do
        [[ -z "$young" ]] && continue
        grep -qF "\\"$young\\"" pnpm-workspace.yaml || refused+=("$young")
      done < "$1"
      (( ${#refused[@]} )) || return 0
      printf 'Error: \\e[31mERR_PNPM_NO_MATURE_MATCHING_VERSION\\e[0m\\n\\n'
      printf '\\e[31m  ╰─▶ \\e[0m%d versions do not meet the minimumReleaseAge constraint:\\n' "${#refused[@]}"
      for young in "${refused[@]}"; do
        printf '\\e[31m      \\e[0m  %s was published at 2026-10-\\n' "$young"
        printf '\\e[31m      \\e[0m15T13:13:29.674Z, within the minimumReleaseAge cutoff\\n'
      done
      exit 1
    }

    cmd="$(basename "$0") $*"
    echo "$cmd${HEX_COOLDOWN:+ HEX_COOLDOWN=$HEX_COOLDOWN}" >> '#{base}/log'
    case "$cmd" in
      "pnpm audit --json")
        if [[ -e '#{base}/js-fixed' ]]; then echo '{"advisories": {}}'; exit 0; fi
        cat '#{base}/audit.json'; exit 1 ;;
      "pnpm -r update "*)
        cp pnpm-workspace.yaml '#{base}/workspace-seen'
        refuse '#{base}/young'
        [[ -e '#{base}/fail-update' ]] && { echo "ERR_PNPM_BROKEN"; exit 1; }
        # With floor-fixes, a release 24h old fixes the advisory.
        if [[ -e '#{base}/floor-fixes' ]]; then touch '#{base}/js-fixed'; fi
        exit 0 ;;
      # pnpm checks the lockfile against minimumReleaseAge too.
      "pnpm install --frozen-lockfile --ignore-scripts --prefer-offline")
        refuse '#{base}/locked-young' ;;
      "mix hex.audit")
        if [[ -e '#{base}/hex-fixed' ]]; then echo "No retired or vulnerable packages found."; exit 0; fi
        cat '#{base}/hex-audit'
        [[ -e '#{base}/hex-audit-err' ]] && cat '#{base}/hex-audit-err' >&2
        exit "$(cat '#{base}/hex-audit-code' 2>/dev/null || echo 0)" ;;
      "mix deps.update "*)
        if [[ -e '#{base}/floor-fixes' ]]; then touch '#{base}/hex-fixed'; fi
        exit 0 ;;
    esac
    """)

    File.chmod!(Path.join(stubs, "stub"), 0o755)
    for tool <- ~w(pnpm mix), do: File.ln_s!("stub", Path.join(stubs, tool))

    %{base: base, work: work, path: stubs <> ":" <> System.fetch_env!("PATH")}
  end

  test "with no advisory nothing is updated", ctx do
    assert {_, 0} = fixes(ctx)
    assert log(ctx) == ["pnpm audit --json", "mix hex.audit"]
  end

  test "a direct JS dependency is updated to latest with the floor lifted for it", ctx do
    audit(ctx, ["vite"])

    assert {out, 0} = fixes(ctx)
    assert out =~ "vite has an advisory; updated it under the 24h floor."
    assert "pnpm -r update --ignore-scripts --latest vite" in log(ctx)
    assert seen(ctx) =~ ~s(minimumReleaseAgeExclude:\n  - "vite"\n)
    # The lockfile holds no young version, so nothing stays excluded.
    assert workspace(ctx) == @workspace
  end

  test "a transitive JS dependency is updated within its ranges", ctx do
    audit(ctx, ["esbuild", "esbuild"])

    assert {_, 0} = fixes(ctx)
    # Under the floor first, then with it lifted.
    assert Enum.filter(log(ctx), &(&1 =~ "update")) ==
             List.duplicate("pnpm -r update --ignore-scripts esbuild", 2)
  end

  test "a JS fix 24h old is taken without lifting the floor", ctx do
    audit(ctx, ["vite"])
    File.touch!(Path.join(ctx.base, "floor-fixes"))

    assert {out, 0} = fixes(ctx)
    assert out =~ "vite has an advisory; updated it to a fix 24h old."

    assert Enum.filter(log(ctx), &(&1 =~ "update")) == [
             "pnpm -r update --ignore-scripts --latest vite"
           ]

    refute seen(ctx) =~ "minimumReleaseAgeExclude"
    assert workspace(ctx) == @workspace
  end

  test "a Hex fix 24h old is taken without lifting the cooldown", ctx do
    hex_audit(ctx, "Advisories:\n  plug 1.18.0 - GHSA-aaaa: Header injection\n")
    File.touch!(Path.join(ctx.base, "floor-fixes"))

    assert {out, 0} = fixes(ctx)
    assert out =~ "plug had advisories; updated to fixes 24h old."
    assert Enum.filter(log(ctx), &(&1 =~ "deps.update")) == ["mix deps.update plug"]
  end

  test "commits an exact exclusion for each young version the fix locks", ctx do
    audit(ctx, ["vite"])
    File.write!(Path.join(ctx.base, "young"), "@esbuild/darwin-arm64@0.30.1\nrollup@5.0.1\n")
    File.write!(Path.join(ctx.base, "locked-young"), "vite@8.3.2\n")

    assert {out, 0} = fixes(ctx)
    # Refused under the floor, then once more with the young versions refused.
    assert length(Enum.filter(log(ctx), &(&1 =~ "update"))) == 3

    assert seen(ctx) =~
             ~s(  - "vite"\n  - "@esbuild/darwin-arm64@0.30.1"\n  - "rollup@5.0.1"\n)

    assert workspace(ctx) ==
             @workspace <>
               "\n# Releases under 24h old taken to fix an advisory; scripts/age-excludes.ts\n" <>
               "# drops each once it is 24h old.\nminimumReleaseAgeExclude:\n" <>
               ~s(  - "@esbuild/darwin-arm64@0.30.1"\n  - "rollup@5.0.1"\n  - "vite@8.3.2"\n)

    assert out =~ "excluded @esbuild/darwin-arm64@0.30.1, rollup@5.0.1, vite@8.3.2 until 24h old"
  end

  test "keeps the exclusions already committed", ctx do
    audit(ctx, ["vite"])
    File.write!(Path.join(ctx.base, "locked-young"), "vite@8.3.2\nsvelte@5.9.0\n")

    File.write!(
      Path.join(ctx.work, "pnpm-workspace.yaml"),
      @workspace <> ~s(\nminimumReleaseAgeExclude:\n  - "svelte@5.9.0"\n)
    )

    assert {_, 0} = fixes(ctx)
    assert workspace(ctx) =~ ~s(minimumReleaseAgeExclude:\n  - "svelte@5.9.0"\n  - "vite@8.3.2"\n)
  end

  test "an update failing for another reason refuses, restoring the workspace", ctx do
    audit(ctx, ["vite"])
    File.touch!(Path.join(ctx.base, "fail-update"))

    assert {out, 1} = fixes(ctx)

    assert out =~
             "pre-commit: pnpm -r update --ignore-scripts --latest vite failed:\nERR_PNPM_BROKEN"

    assert workspace(ctx) == @workspace
  end

  test "an unreadable pnpm audit refuses", ctx do
    File.write!(Path.join(ctx.base, "audit.json"), "ERR_PNPM_AUDIT_BAD_RESPONSE")

    assert {out, 1} = fixes(ctx)
    assert out =~ "pnpm audit produced no JSON report"
  end

  test "an advisory naming no package refuses", ctx do
    File.write!(Path.join(ctx.base, "audit.json"), ~s({"advisories": {"1": {}}}))

    assert {out, 1} = fixes(ctx)
    assert out =~ "pnpm audit named no package for an advisory."
  end

  test "Hex packages with advisories are updated with the cooldown off", ctx do
    hex_audit(ctx, """
    Advisories:
      plug 1.18.0 - GHSA-aaaa: Header injection
      bandit 1.8.0 - GHSA-bbbb: Request smuggling
      plug 1.18.0 - GHSA-cccc: Cookie parsing
    Retired packages:
      jason 1.4.0 - Deprecated
    """)

    assert {out, 0} = fixes(ctx)
    assert out =~ "plug, bandit had advisories; updated under the 24h floor."
    assert "mix deps.update plug bandit HEX_COOLDOWN=0d" in log(ctx)
  end

  test "only retired Hex packages update nothing", ctx do
    hex_audit(ctx, "Retired packages:\n  jason 1.4.0 - Deprecated\n")

    assert {_, 0} = fixes(ctx)
    refute Enum.any?(log(ctx), &(&1 =~ "deps.update"))
  end

  test "an unfetched Hex record refuses", ctx do
    File.write!(Path.join(ctx.base, "hex-audit-err"), "Failed to fetch record for plug\n")

    assert {out, 1} = fixes(ctx)
    assert out =~ "Hex could not fetch every package's record:\nFailed to fetch record for plug"
  end

  test "a failing hex.audit with no report refuses", ctx do
    hex_audit(ctx, "** (Mix) boom\n")

    assert {out, 1} = fixes(ctx)
    assert out =~ "mix hex.audit failed (exit 1):"
  end

  defp audit(ctx, names) do
    advisories =
      names |> Enum.with_index() |> Map.new(fn {n, i} -> {"#{i}", %{"module_name" => n}} end)

    File.write!(Path.join(ctx.base, "audit.json"), Jason.encode!(%{"advisories" => advisories}))
  end

  defp hex_audit(ctx, out) do
    File.write!(Path.join(ctx.base, "hex-audit"), out)
    File.write!(Path.join(ctx.base, "hex-audit-code"), "1")
  end

  defp log(ctx),
    do: ctx.base |> Path.join("log") |> File.read!() |> String.split("\n", trim: true)

  defp seen(ctx), do: File.read!(Path.join(ctx.base, "workspace-seen"))
  defp workspace(ctx), do: File.read!(Path.join(ctx.work, "pnpm-workspace.yaml"))

  defp fixes(ctx) do
    System.cmd("bun", [@script], cd: ctx.work, env: [{"PATH", ctx.path}], stderr_to_stdout: true)
  end
end
