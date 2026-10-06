defmodule Meerkat.OutdatedGateTest do
  # Runs the repo's real scripts/outdated.sh against an exemption table
  # each test writes. Only mix, pnpm, curl and gh are replaced, by stubs on
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
    registry_out = Path.join(base, "pnpm-registry.json")
    hex_api = Path.join(base, "hex-api")
    github_api = Path.join(base, "github-api")
    refuse = Path.join(base, "refuse")
    scratch_log = Path.join(base, "scratch.log")

    File.mkdir_p!(Path.join(base, "scripts"))
    File.mkdir_p!(refuse)

    for file <- ~w(package.json pnpm-workspace.yaml pnpm-lock.yaml assets/package.json) do
      File.mkdir_p!(Path.dirname(Path.join(base, file)))
      File.write!(Path.join(base, file), "base\n")
    end

    File.write!(Path.join(base, "mix.lock"), @hex_lock)

    for script <- ~w(outdated.sh deps-common.sh) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([base, "scripts", script]))
    end

    File.write!(hex_out, @hex_header <> "mdex  0.14.1  0.14.1  Up-to-date\n")
    File.write!(pnpm_out, "{}")

    File.mkdir_p!(stubs)
    File.mkdir_p!(hex_api)

    File.write!(Path.join(stubs, "stub"), """
    #!/usr/bin/env bash
    case "$(basename "$0") $*" in
      "mix hex.outdated") cat '#{hex_out}'; exit 1 ;;
      "pnpm -r outdated --format json") cat '#{pnpm_out}'; exit 1 ;;
      "pnpm -r outdated --format json --config.minimum-release-age=0")
        if [[ -e '#{registry_out}' ]]; then cat '#{registry_out}'; else cat '#{pnpm_out}'; fi
        exit 1 ;;
      "pnpm -r update --latest --lockfile-only --ignore-scripts "*)
        # Only a scratch copy of the workspace, without the repo's scripts/.
        [[ ! -e scripts && -f package.json && -f pnpm-workspace.yaml && -f pnpm-lock.yaml &&
           -f assets/package.json && -L deps ]] || { echo "not a scratch workspace copy"; exit 1; }
        echo "updated $6" | tee -a package.json >> pnpm-lock.yaml
        echo "$PWD" >> '#{scratch_log}'
        if [[ -e '#{refuse}'/"$6" ]]; then cat '#{refuse}'/"$6"; exit 1; fi ;;
      "curl "*/api/packages/*) url="${@: -1}"; cat '#{hex_api}'/"${url##*/}.json" ;;
      "curl "*api.github.com/*)
        cat >>'#{base}/curl-config'
        url="${@: -1}"; f='#{github_api}'/"${url#https://api.github.com/}"
        if [[ -e "$f" ]]; then cat "$f"; printf '\\n%s' "$(cat "$f.code" 2>/dev/null || echo 200)"
        else printf '\\n404'; fi ;;
      "gh auth token") cat '#{base}/gh-token' 2>/dev/null ;;
    esac
    """)

    File.chmod!(Path.join(stubs, "stub"), 0o755)
    for tool <- ~w(mix pnpm curl gh), do: File.ln_s!("stub", Path.join(stubs, tool))

    {:ok,
     base: base,
     stubs: stubs,
     hex_out: hex_out,
     pnpm_out: pnpm_out,
     registry_out: registry_out,
     hex_api: hex_api,
     github_api: github_api,
     refuse: refuse,
     scratch_log: scratch_log}
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

    for file <- [ctx.registry_out, ctx.pnpm_out], report <- ["", "[]", ~s("oops"), "null"] do
      File.write!(ctx.registry_out, "{}")
      File.write!(ctx.pnpm_out, "{}")
      File.write!(file, report)
      assert {out, 1} = run(ctx)
      assert out =~ "cannot check JS deps"
      assert out =~ "--config.minimum-release-age=0 produced" == (file == ctx.registry_out)
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

  # pnpm outdated reports the newest release past minimumReleaseAge as
  # latest, so a release under 24h shows only once the floor is off.
  describe "a JS release under 24h that pnpm outdated does not report" do
    setup ctx do
      File.write!(ctx.pnpm_out, ~s({"shiki": {"current": "3.23.0", "latest": "4.4.2"}}))
      File.write!(ctx.registry_out, ~s({"shiki": {"current": "3.23.0", "latest": "4.4.3"}}))
    end

    test "leaves the release pnpm reports required", ctx do
      exempt(ctx, %{})

      assert {out, 1} = run(ctx)
      assert out =~ "BLOCKED: shiki is outdated (latest: 4.4.2)"
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
  end

  # pnpm outdated leaves out a package installed at the newest release
  # past minimumReleaseAge, though a younger release makes it behind.
  describe "a JS release under 24h when pnpm outdated leaves the package out" do
    setup ctx do
      File.write!(ctx.registry_out, ~s({"shiki": {"current": "4.4.2", "latest": "4.4.3"}}))
    end

    test "passes the gate without an exemption", ctx do
      exempt(ctx, %{})

      assert {out, 0} = run(ctx)
      assert out =~ "all dependencies current."
    end

    test "is covered by an exemption naming it", ctx do
      exempt(ctx, %{"shiki" => entry("4.4.3")})

      assert {out, 0} = run(ctx)
      assert out =~ "exempt: shiki@4.4.3"
    end

    test "makes an exemption for an older release stale", ctx do
      exempt(ctx, %{"shiki" => entry("4.4.1")})

      assert {out, 1} = run(ctx)
      assert out =~ "stale exemption: shiki covers 4.4.1, but latest is 4.4.3"
      refute out =~ "BLOCKED"
      refute out =~ "not behind latest"
    end
  end

  describe "a JS release pnpm outdated reports but pnpm refuses to install" do
    setup ctx do
      exempt(ctx, %{})
      File.write!(ctx.pnpm_out, ~s({"lefthook": {"current": "2.1.16", "latest": "2.1.17"}}))

      File.write!(
        Path.join(ctx.refuse, "lefthook"),
        " ERR_PNPM_NO_MATURE_MATCHING_VERSION  Version 2.1.17 (released 24 hours ago) of lefthook-windows-x64 does not meet the minimumReleaseAge constraint\n"
      )
    end

    test "passes the gate when a package version it requires is under 24h", ctx do
      assert {out, 0} = run(ctx)
      assert out =~ "ERR_PNPM_NO_MATURE_MATCHING_VERSION  Version 2.1.17"
      assert out =~ "too young: lefthook@2.1.17 requires a package version under the 24h floor"
    end

    test "checks it on a scratch copy it removes, leaving the tree alone", ctx do
      assert {_, 0} = run(ctx)
      assert [scratch] = ctx.scratch_log |> File.read!() |> String.split("\n", trim: true)
      refute File.exists?(scratch)

      for file <- ~w(package.json pnpm-workspace.yaml pnpm-lock.yaml assets/package.json) do
        assert File.read!(Path.join(ctx.base, file)) == "base\n"
      end
    end

    test "blocks the push when it cannot copy the workspace", ctx do
      File.rm!(Path.join(ctx.base, "pnpm-workspace.yaml"))

      assert {out, 1} = run(ctx)
      assert out =~ "could not copy the workspace to a scratch dir — cannot check lefthook"
    end

    test "blocks the push when pnpm fails for another reason", ctx do
      File.write!(Path.join(ctx.refuse, "lefthook"), " ERR_PNPM_META_FETCH_FAIL  GET failed\n")

      assert {out, 1} = run(ctx)
      assert out =~ "ERR_PNPM_META_FETCH_FAIL"
      assert out =~ "pnpm could not resolve lefthook's latest release (exit 1)"
    end
  end

  test "each exempted JS package passes, and an unexempted one blocks", ctx do
    exempt(ctx, %{"shiki" => entry("4.4.3"), "vite" => entry("8.3.2")})

    report = ~s({"shiki": {"current": "3.23.0", "latest": "4.4.3"},
                 "vite": {"current": "8.2.0", "latest": "8.3.2"},
                 "lefthook": {"current": "2.1.0", "latest": "2.1.16"}})

    File.write!(ctx.pnpm_out, report)
    File.write!(ctx.registry_out, report)

    assert {out, 1} = run(ctx)
    assert out =~ "exempt: shiki@4.4.3"
    assert out =~ "exempt: vite@8.3.2"
    refute out =~ "BLOCKED: shiki"
    refute out =~ "BLOCKED: vite"
    assert out =~ "BLOCKED: lefthook is outdated (latest: 2.1.16)"
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
      hex_release(ctx, "muex", git_release("0.11.2", "upstream/muex.git"))
      hex_release(ctx, "plug_x", git_release("1.0.0", "upstream/plug_x"))
      compare(ctx, "upstream/muex", "v0.11.2...someone:muex:a628d48", "ahead")
      compare(ctx, "upstream/plug_x", "v1.0.0...someone:plug_x:b1c2d3e", "identical")
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

    test "fails when the pinned commit does not contain the named release", ctx do
      exempt(ctx, %{"muex" => entry("0.11.2"), "plug_x" => entry("1.0.0")})
      # The v-tag verdict stands; the gate does not go on to try this one.
      compare(ctx, "upstream/muex", "0.11.2...someone:muex:a628d48", "ahead")

      for status <- ["diverged", "behind"] do
        compare(ctx, "upstream/muex", "v0.11.2...someone:muex:a628d48", status)
        assert {out, 1} = run(ctx)

        assert out =~
                 "BLOCKED: muex is pinned to a628d48, which does not contain upstream/muex v0.11.2"

        refute out =~ "plug_x is pinned"
      end
    end

    test "finds a release tag without a v prefix", ctx do
      exempt(ctx, %{"muex" => entry("0.11.2"), "plug_x" => entry("1.0.0")})

      File.rm!(
        Path.join(ctx.github_api, "repos/upstream/plug_x/compare/v1.0.0...someone:plug_x:b1c2d3e")
      )

      compare(ctx, "upstream/plug_x", "1.0.0...someone:plug_x:b1c2d3e", "ahead")

      assert {_out, 0} = run(ctx)
    end

    test "fails closed when GitHub finds neither release tag", ctx do
      exempt(ctx, %{"muex" => entry("0.11.2"), "plug_x" => entry("1.0.0")})

      File.rm!(
        Path.join(ctx.github_api, "repos/upstream/muex/compare/v0.11.2...someone:muex:a628d48")
      )

      assert {out, 1} = run(ctx)

      assert out =~
               "BLOCKED: muex — GitHub finds neither tag v0.11.2 nor 0.11.2 in upstream/muex, or not pin a628d48"
    end

    test "fails closed when GitHub's comparison is unreadable", ctx do
      exempt(ctx, %{"muex" => entry("0.11.2"), "plug_x" => entry("1.0.0")})

      for report <- ["", "{}", "not json"] do
        compare(ctx, "upstream/muex", "v0.11.2...someone:muex:a628d48", nil, report)
        assert {out, 1} = run(ctx)

        assert out =~
                 "BLOCKED: muex — could not read GitHub's comparison of its pin with upstream/muex v0.11.2"
      end
    end

    test "fails closed on any other HTTP answer, naming a likely rate limit", ctx do
      exempt(ctx, %{"muex" => entry("0.11.2"), "plug_x" => entry("1.0.0")})
      # A later tag spelling would pass, but an error answer is not a missing tag.
      compare(ctx, "upstream/muex", "0.11.2...someone:muex:a628d48", "ahead")

      for code <- [403, 429, 500] do
        compare(ctx, "upstream/muex", "v0.11.2...someone:muex:a628d48", nil, "{}", code)
        assert {out, 1} = run(ctx)

        assert out =~
                 "BLOCKED: muex — GitHub answered HTTP #{code} comparing its pin with upstream/muex v0.11.2"

        assert out =~ "may be rate-limiting" == (code != 500)
      end
    end

    test "sends GITHUB_TOKEN, or else gh's token, to GitHub", ctx do
      exempt(ctx, %{"muex" => entry("0.11.2"), "plug_x" => entry("1.0.0")})
      config = Path.join(ctx.base, "curl-config")
      File.write!(Path.join(ctx.base, "gh-token"), "gh-t0k")

      assert {_out, 0} = run(ctx)
      assert File.read!(config) =~ ~s(header = "Authorization: Bearer gh-t0k")

      File.rm!(config)
      assert {_out, 0} = run(ctx, "env-t0k")
      assert File.read!(config) =~ ~s(header = "Authorization: Bearer env-t0k")
      refute File.read!(config) =~ "gh-t0k"
    end

    test "fails closed when Hex links no GitHub repo", ctx do
      exempt(ctx, %{"muex" => entry("0.11.2"), "plug_x" => entry("1.0.0")})
      hex_release(ctx, "muex", ~s({"latest_stable_version": "0.11.2"}))

      assert {out, 1} = run(ctx)
      assert out =~ "BLOCKED: muex — Hex links no GitHub repo to find release 0.11.2 in"
    end

    test "fails closed when mix.lock pins it outside https://github.com", ctx do
      exempt(ctx, %{"muex" => entry("0.11.2"), "plug_x" => entry("1.0.0")})

      File.write!(
        Path.join(ctx.base, "mix.lock"),
        String.replace(@git_lock, "https://github.com/", "https://gitlab.com/")
      )

      assert {out, 1} = run(ctx)
      assert out =~ "BLOCKED: muex — mix.lock pins it to no https://github.com commit"
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

  # The Funding link sorts first, so the gate must prefer the GitHub key.
  defp git_release(version, repo),
    do:
      Jason.encode!(%{
        "latest_stable_version" => version,
        "meta" => %{
          "links" => %{
            "Funding" => "https://github.com/sponsors/upstream",
            "GitHub" => "https://github.com/" <> repo
          }
        }
      })

  # Writes GitHub's compare report for BASE...HEAD in REPO, and its HTTP
  # code, as the curl stub serves them; a range without one serves 404.
  defp compare(ctx, repo, range, status, report \\ nil, code \\ 200) do
    path = Path.join([ctx.github_api, "repos", repo, "compare", range])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, report || Jason.encode!(%{"status" => status}))
    File.write!(path <> ".code", to_string(code))
  end

  defp behind(ctx) do
    File.write!(ctx.pnpm_out, ~s({"shiki": {"current": "3.23.0", "latest": "4.4.3"}}))
    File.write!(ctx.hex_out, @hex_header <> "plug  1.20.3  2.1.0  Update not possible\n")
  end

  defp run(ctx, token \\ nil) do
    path = ctx.stubs <> ":" <> System.fetch_env!("PATH")

    System.cmd("bash", [Path.join(ctx.base, "scripts/outdated.sh")],
      env: [{"PATH", path}, {"GITHUB_TOKEN", token}],
      stderr_to_stdout: true
    )
  end
end
