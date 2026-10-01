defmodule Meerkat.OutdatedGateTest do
  # Runs the repo's real scripts/outdated.sh against an exemption table
  # each test writes. Only mix, pnpm and curl are replaced, by stubs on
  # PATH that report the outdated packages a test sets up.
  use ExUnit.Case, async: true

  @root File.cwd!()

  @hex_header "Dependency  Only  Current  Latest  Status\n"

  @hex_lock """
  %{
    "mdex": {:hex, :mdex, "0.14.1", "abc", [:mix], [], "hexpm", "def"},
  }
  """

  @git_lock """
  %{
    "mdex": {:hex, :mdex, "0.14.1", "abc", [:mix], [], "hexpm", "def"},
    "muex": {:git, "https://github.com/someone/muex.git", "a628d48", [ref: "a628d48"]},
    "plug_x": {:git, "https://github.com/someone/plug_x.git", "b1c2d3e", [ref: "b1c2d3e"]},
  }
  """

  setup do
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-outdated")
    on_exit(fn -> File.rm_rf!(base) end)

    stubs = Path.join(base, "stubs")
    hex_out = Path.join(base, "hex.out")
    pnpm_out = Path.join(base, "pnpm.json")
    pnpm_times = Path.join(base, "pnpm-times.json")
    npm_latest = Path.join(base, "npm-latest")
    hex_api = Path.join(base, "hex-api")

    File.mkdir_p!(Path.join(base, "scripts"))
    File.write!(Path.join(base, "mix.lock"), @hex_lock)

    for script <- ~w(outdated.sh deps-common.sh) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([base, "scripts", script]))
    end

    File.write!(hex_out, @hex_header <> "mdex  0.14.1  0.14.1  Up-to-date\n")
    File.write!(pnpm_out, "{}")
    File.write!(pnpm_times, "{}")

    File.mkdir_p!(stubs)
    File.mkdir_p!(hex_api)
    File.mkdir_p!(npm_latest)

    File.write!(Path.join(stubs, "stub"), """
    #!/usr/bin/env bash
    case "$(basename "$0") $*" in
      "mix hex.outdated") cat '#{hex_out}'; exit 1 ;;
      "pnpm -r outdated --format json") cat '#{pnpm_out}'; exit 1 ;;
      "pnpm view "*" dist-tags.latest")
        if [[ -e '#{npm_latest}'/"$2" ]]; then cat '#{npm_latest}'/"$2"
        else jq -r --arg n "$2" '.[$n].latest' '#{pnpm_out}'; fi ;;
      "pnpm view "*) cat '#{pnpm_times}' ;;
      "curl "*/api/packages/*) url="${@: -1}"; cat '#{hex_api}'/"${url##*/}.json" ;;
    esac
    """)

    File.chmod!(Path.join(stubs, "stub"), 0o755)
    for tool <- ~w(mix pnpm curl), do: File.ln_s!("stub", Path.join(stubs, tool))

    {:ok,
     base: base,
     stubs: stubs,
     hex_out: hex_out,
     pnpm_out: pnpm_out,
     pnpm_times: pnpm_times,
     npm_latest: npm_latest,
     hex_api: hex_api}
  end

  test "a package behind latest without an exemption blocks the push", ctx do
    exempt(ctx, %{})
    File.write!(ctx.pnpm_out, ~s({"vite": {"current": "8.2.0", "latest": "8.3.1"}}))

    File.write!(ctx.hex_out, """
    #{@hex_header}jason  dev,test  1.4.3  1.4.5  Update possible
    plug  1.20.3  2.1.0  Update not possible
    bandit  1.12.4  1.12.5  Update possible (cooldown)
    """)

    assert {out, 1} = run(ctx)
    assert out =~ "BLOCKED: vite is outdated (latest: 8.3.1)"
    assert out =~ "BLOCKED: jason is outdated (latest: 1.4.5)"
    assert out =~ "BLOCKED: plug is outdated (latest: 2.1.0)"
    refute out =~ "bandit is outdated"
  end

  test "current dependencies pass the gate", ctx do
    exempt(ctx, %{})

    assert {out, 0} = run(ctx)
    assert out =~ "all dependencies current."
  end

  test "an unreadable report blocks the push", ctx do
    exempt(ctx, %{})

    for report <- ["", "[]", ~s("oops"), "null"] do
      File.write!(ctx.pnpm_out, report)
      assert {out, 1} = run(ctx)
      assert out =~ "cannot check JS deps"
    end

    File.write!(ctx.pnpm_out, "{}")

    for report <- [
          "** (Mix) boom\n",
          @hex_header <> "** (Mix) Could not fetch registry\n",
          @hex_header <> "plug  1.20.3  2.1.1  Update retired (cooldown)\n",
          @hex_header <> "plug  1.20.3  2.1.1  Update not possible (cooldown)\n"
        ] do
      File.write!(ctx.hex_out, report)
      assert {out, 1} = run(ctx)
      assert out =~ "cannot check Hex deps"
    end
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

  test "a JS release under 24h passes the gate without an exemption", ctx do
    exempt(ctx, %{})
    File.write!(ctx.pnpm_out, ~s({"shiki": {"current": "3.23.0", "latest": "4.4.3"}}))
    published = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()
    File.write!(ctx.pnpm_times, Jason.encode!(%{"4.4.3" => published}))

    assert {out, 0} = run(ctx)
    assert out =~ "grace: shiki@4.4.3 is younger than the 24h release floor"
  end

  # pnpm outdated reports the newest release past minimumReleaseAge as
  # latest, so a release under 24h shows only in the registry's latest.
  describe "a JS release under 24h that pnpm outdated does not report" do
    setup ctx do
      File.write!(ctx.pnpm_out, ~s({"shiki": {"current": "3.23.0", "latest": "4.4.2"}}))
      File.write!(Path.join(ctx.npm_latest, "shiki"), "4.4.3\n")
    end

    test "makes an exemption for the release pnpm reports stale", ctx do
      exempt(ctx, %{"shiki" => entry("4.4.2")})

      assert {out, 1} = run(ctx)
      assert out =~ "stale exemption: shiki covers 4.4.2, but latest is 4.4.3"
    end

    test "is covered by an exemption naming it", ctx do
      exempt(ctx, %{"shiki" => entry("4.4.3")})

      assert {out, 0} = run(ctx)
      assert out =~ "exempt: shiki@4.4.3"
    end

    test "fails closed when the registry's latest is unreadable", ctx do
      exempt(ctx, %{"shiki" => entry("4.4.3")})

      for report <- ["", "4.4.3 4.4.4\n"] do
        File.write!(Path.join(ctx.npm_latest, "shiki"), report)
        assert {out, 1} = run(ctx)
        assert out =~ "could not read shiki's latest release from the registry"
        refute out =~ "stale exemption"
      end
    end
  end

  describe "a Hex release in cooldown" do
    setup ctx do
      File.write!(ctx.hex_out, @hex_header <> "plug  1.20.3  2.1.1  Update possible (cooldown)\n")
    end

    test "passes the gate without an exemption", ctx do
      exempt(ctx, %{})

      assert {out, 0} = run(ctx)
      assert out =~ "cooldown: plug@2.1.1 is in the configured Hex cooldown window"
    end

    test "makes an exemption for an older release stale", ctx do
      exempt(ctx, %{"plug" => entry("2.1.0")})

      assert {out, 1} = run(ctx)
      assert out =~ "stale exemption: plug covers 2.1.0, but latest is 2.1.1"
      refute out =~ "not behind latest"
    end

    test "is covered by an exemption naming it", ctx do
      exempt(ctx, %{"plug" => entry("2.1.1")})

      assert {out, 0} = run(ctx)
      assert out =~ "exempt: plug@2.1.1"
    end
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

  describe "a Hex package taken from git" do
    setup ctx do
      File.write!(Path.join(ctx.base, "mix.lock"), @git_lock)
      hex_release(ctx, "muex", ~s({"latest_stable_version": "0.11.2"}))
      hex_release(ctx, "plug_x", ~s({"latest_stable_version": "1.0.0"}))
    end

    test "blocks the push without an exemption", ctx do
      exempt(ctx, %{"plug_x" => entry("1.0.0")})

      assert {out, 1} = run(ctx)
      assert out =~ "exempt: plug_x@1.0.0"
      assert out =~ "BLOCKED: muex is a git dependency (latest Hex release: 0.11.2)"
      assert out =~ "add or update its exemption"
    end

    test "passes with an exemption naming its latest Hex release", ctx do
      exempt(ctx, %{"muex" => entry("0.11.2"), "plug_x" => entry("1.0.0")})

      assert {out, 0} = run(ctx)
      assert out =~ "exempt: muex@0.11.2"
      assert out =~ "exempt: plug_x@1.0.0"
    end

    test "fails once a newer Hex release is out", ctx do
      exempt(ctx, %{"muex" => entry("0.11.1"), "plug_x" => entry("1.0.0")})

      assert {out, 1} = run(ctx)
      assert out =~ "stale exemption: muex covers 0.11.1, but latest is 0.11.2"
    end

    test "fails closed when Hex reports no release", ctx do
      exempt(ctx, %{"muex" => entry("0.11.2"), "plug_x" => entry("1.0.0")})

      for report <- ["", "{}", "not json"] do
        hex_release(ctx, "muex", report)
        assert {out, 1} = run(ctx)
        assert out =~ "BLOCKED: muex — no latest Hex release found"
        refute out =~ "stale exemption"
      end
    end

    test "fails closed when mix.lock is unreadable", ctx do
      exempt(ctx, %{})
      File.rm!(Path.join(ctx.base, "mix.lock"))

      assert {out, 1} = run(ctx)
      assert out =~ "could not read mix.lock"
    end
  end

  defp entry(version), do: %{"version" => version, "reason" => "upstream needs shiki 3"}

  defp exempt(ctx, table),
    do: File.write!(Path.join(ctx.base, "scripts/dep-exemptions.json"), Jason.encode!(table))

  defp hex_release(ctx, name, report),
    do: File.write!(Path.join(ctx.hex_api, name <> ".json"), report)

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
