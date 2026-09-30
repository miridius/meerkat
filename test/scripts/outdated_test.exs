defmodule Meerkat.OutdatedGateTest do
  # Runs the repo's real scripts/outdated.sh against an exemption table
  # each test writes. Only mix, pnpm and curl are replaced, by stubs on
  # PATH that report the outdated packages a test sets up.
  use ExUnit.Case, async: true

  @root File.cwd!()

  @hex_header "Dependency  Only  Current  Latest  Status\n"

  setup do
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-outdated")
    on_exit(fn -> File.rm_rf!(base) end)

    stubs = Path.join(base, "stubs")
    hex_out = Path.join(base, "hex.out")
    pnpm_out = Path.join(base, "pnpm.json")

    File.mkdir_p!(Path.join(base, "scripts"))
    File.cp!(Path.join(@root, "scripts/outdated.sh"), Path.join(base, "scripts/outdated.sh"))

    File.write!(hex_out, @hex_header <> "mdex  0.14.1  0.14.1  Up-to-date\n")
    File.write!(pnpm_out, "{}")

    File.mkdir_p!(stubs)

    File.write!(Path.join(stubs, "stub"), """
    #!/usr/bin/env bash
    case "$(basename "$0") $*" in
      "mix hex.outdated") cat '#{hex_out}'; exit 1 ;;
      "pnpm -r outdated --format json") cat '#{pnpm_out}'; exit 1 ;;
      "pnpm view "*) echo '{}' ;;
    esac
    """)

    File.chmod!(Path.join(stubs, "stub"), 0o755)
    for tool <- ~w(mix pnpm curl), do: File.ln_s!("stub", Path.join(stubs, tool))

    {:ok, base: base, stubs: stubs, hex_out: hex_out, pnpm_out: pnpm_out}
  end

  test "an exemption covering the latest release passes the gate", ctx do
    exempt(ctx, %{"shiki" => entry("4.4.3"), "plug" => entry("2.1.0")})
    behind(ctx)

    assert {out, 0} = run(ctx)
    assert out =~ "exempt: shiki@4.4.3 (upstream needs shiki 3)"
    assert out =~ "exempt: plug@2.1.0"
  end

  test "an exemption for an older release fails once a newer one is out", ctx do
    exempt(ctx, %{"shiki" => entry("4.4.2"), "plug" => entry("2.1.0")})
    behind(ctx)

    assert {out, 1} = run(ctx)
    assert out =~ "stale exemption: shiki covers 4.4.2, but latest is 4.4.3"
    assert out =~ "BLOCKED: shiki is outdated (latest: 4.4.3)"
  end

  test "an exemption for a package that is not behind fails the gate", ctx do
    exempt(ctx, %{"shiki" => entry("4.4.3"), "jason" => entry("1.4.5")})
    File.write!(ctx.pnpm_out, ~s({"shiki": {"current": "3.23.0", "latest": "4.4.3"}}))

    assert {out, 1} = run(ctx)
    assert out =~ "stale exemption: jason is not behind latest; remove its entry"
  end

  test "an exemption without a version or reason fails the gate", ctx do
    for bad <- ["held back", entry(""), %{"version" => "4.4.3", "reason" => ""}] do
      exempt(ctx, %{"shiki" => bad})

      assert {out, 1} = run(ctx)
      assert out =~ ~s(each entry needs a "version" and a "reason")
    end
  end

  defp entry(version), do: %{"version" => version, "reason" => "upstream needs shiki 3"}

  defp exempt(ctx, table),
    do: File.write!(Path.join(ctx.base, "scripts/dep-exemptions.json"), Jason.encode!(table))

  defp behind(ctx) do
    File.write!(ctx.pnpm_out, ~s({"shiki": {"current": "3.23.0", "latest": "4.4.3"}}))
    File.write!(ctx.hex_out, @hex_header <> "plug  1.20.3  2.1.0  Update not possible\n")
  end

  defp run(ctx) do
    path = ctx.stubs <> ":" <> System.fetch_env!("PATH")

    System.cmd("bash", [Path.join(ctx.base, "scripts/outdated.sh")],
      env: [{"PATH", path}],
      stderr_to_stdout: true
    )
  end
end
