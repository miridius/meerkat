defmodule Meerkat.ToolchainTest do
  # Runs the repo's real scripts/toolchain.ts against pins each test
  # writes. Only curl and gh are replaced, by stubs on PATH: curl serves
  # the file a test wrote for a URL, `[]` for any other GitHub API URL,
  # and fails for the rest.
  use ExUnit.Case, async: true

  @script Path.join(File.cwd!(), "scripts/toolchain.ts")

  @old "2020-01-01T00:00:00Z"

  @tool_versions "erlang 29.1.2\nelixir 1.20.4\nbun 1.4.3\n"

  @env """
  # pins
  HEX_VERSION=2.5.3
  REBAR3_VERSION=3.27.3
  REBAR3_SHA256=aaa
  CLJ_KONDO_VERSION=2026.08.04
  CLJ_KONDO_SHA256=bbb
  PLANTUML_VERSION=1.2026.8
  PLANTUML_SHA256=ccc
  GNU_BASH_VERSION=5.3.2
  GNU_BASH_SHA256=ddd
  GRAPHVIZ_VERSION=16.1.0
  GRAPHVIZ_SHA256=eee
  """

  @checkout_sha String.duplicate("a", 40)
  @checkout_next String.duplicate("b", 40)

  @ci """
  jobs:
    test:
      steps:
        - uses: actions/checkout@#{@checkout_sha} # v7.0.1
        - uses: ./.github/actions/local
  """

  @audit """
  jobs:
    audit:
      steps:
        - uses: actions/checkout@#{@checkout_sha} # v7.0.1
  """

  setup do
    base = Meerkat.TestHelpers.tmp_path("meerkat-toolchain")
    on_exit(fn -> File.rm_rf!(base) end)

    web = Path.join(base, "web")
    stubs = Path.join(base, "stubs")
    File.mkdir_p!(web)
    File.mkdir_p!(stubs)
    File.mkdir_p!(Path.join(base, ".github/workflows"))

    File.write!(Path.join(base, ".github/toolchain.env"), @env)
    File.write!(Path.join(base, ".tool-versions"), @tool_versions)
    File.write!(Path.join(base, ".github/workflows/ci.yml"), @ci)
    File.write!(Path.join(base, ".github/workflows/audit.yml"), @audit)

    File.write!(
      Path.join(base, "package.json"),
      ~s({\n  "name": "x",\n  "packageManager": "pnpm@12.11.2"\n}\n)
    )

    File.write!(Path.join(stubs, "curl"), """
    #!/usr/bin/env bash
    cat >> '#{base}/curl-config'
    url="${@: -1}"
    f='#{web}'/"$(printf %s "$url" | tr -c 'A-Za-z0-9' '_')"
    if [[ -e "$f" ]]; then cat "$f"
    elif [[ "$url" == https://api.github.com/* ]]; then echo '[]'
    else echo "curl: (22) 404 $url" >&2; exit 22; fi
    """)

    File.write!(Path.join(stubs, "gh"), "#!/bin/sh\nexit 1\n")

    # Re-locks pnpm, refusing as pnpm 12 does each version listed in
    # pnpm-young that pnpm-workspace.yaml does not exclude.
    File.write!(Path.join(base, "pnpm-young"), "")
    File.write!(Path.join(base, "pnpm-workspace.yaml"), "minimumReleaseAge: 1440\n")

    File.write!(Path.join(stubs, "pnpm"), """
    #!/usr/bin/env bash
    echo "pnpm $*" >> '#{base}/pnpm-log'
    [[ "$*" == "install --lockfile-only --ignore-scripts" ]] || exit 1
    refused=()
    while read -r young; do
      [[ -z "$young" ]] && continue
      grep -qF "\\"$young\\"" pnpm-workspace.yaml || refused+=("$young")
    done < '#{base}/pnpm-young'
    for young in "${refused[@]}"; do
      printf '\\e[31m      \\e[0m  %s was published at 2026-10-\\n' "$young"
      printf '\\e[31m      \\e[0m15T13:13:29.674Z, within the minimumReleaseAge cutoff\\n'
    done
    (( ${#refused[@]} == 0 ))
    """)

    for stub <- ~w(curl gh pnpm), do: File.chmod!(Path.join(stubs, stub), 0o755)

    ctx = %{base: base, web: web, path: stubs <> ":" <> System.fetch_env!("PATH")}
    world(ctx)
    ctx
  end

  # Every pin is the newest release, published long ago.
  defp world(ctx) do
    github(ctx, "oven-sh/bun", [{"bun-v1.4.3", @old}])
    otp(ctx, [{"29.1.2", @old}])
    elixir(ctx, [{"1.20.4-otp-29", @old}])
    github(ctx, "hexpm/hex", [{"v2.5.3", @old}])
    github(ctx, "erlang/rebar3", [{"3.27.3", @old}])
    github(ctx, "clj-kondo/clj-kondo", [{"v2026.08.04", @old}])
    github(ctx, "plantuml/plantuml", [{"v1.2026.8", @old}, {"snapshot", @old, true}])
    bash(ctx, "5.3", [{1, @old}, {2, @old}])
    graphviz(ctx, [{"16.1.0", @old}, {"16.0.0", @old}])

    serve(
      ctx,
      "https://registry.npmjs.org/pnpm",
      Jason.encode!(%{
        "dist-tags" => %{"latest" => "12.11.2"},
        "time" => %{"created" => @old, "12.11.2" => @old, "12.14.0" => @old}
      })
    )

    github(ctx, "actions/checkout", [{"v7.0.1", @old}])
    commit(ctx, "actions/checkout", "v7.0.1", @checkout_sha)
  end

  test "pins on their targets pass the check", ctx do
    assert {out, 0} = toolchain(ctx, "check")
    assert out =~ "current: bun 1.4.3"
    assert out =~ "current: GNU bash 5.3.2"
    # pnpm's next-12 release is not past its latest dist-tag.
    assert out =~ "current: pnpm 12.11.2"
    assert out =~ "current: actions/checkout v7.0.1"
  end

  test "sends GITHUB_TOKEN to GitHub in a config on stdin", ctx do
    assert {_, 0} = toolchain(ctx, "check")
    assert File.read!(Path.join(ctx.base, "curl-config")) =~ "Authorization: Bearer t0k"
  end

  describe "a newer release" do
    test "at least 24h old is the target", ctx do
      github(ctx, "oven-sh/bun", [{"bun-v1.4.3", @old}, {"bun-v1.4.10", hours_ago(25)}])

      assert {out, 1} = toolchain(ctx, "check")
      assert out =~ "BLOCKED: bun is pinned to 1.4.3; the target is 1.4.10"

      assert {_, 0} = toolchain(ctx, "bump")
      assert tools(ctx) =~ "\nbun 1.4.10\n"
      assert {_, 0} = toolchain(ctx, "check")
    end

    test "under 24h old is not yet the target", ctx do
      github(ctx, "oven-sh/bun", [{"bun-v1.4.4", hours_ago(23)}, {"bun-v1.4.3", @old}])
      elixir(ctx, [{"1.20.4-otp-29", @old}, {"1.20.5-otp-29", hours_ago(1)}])
      bash(ctx, "5.3", [{1, @old}, {2, @old}, {3, hours_ago(2)}])

      assert {_, 0} = toolchain(ctx, "check")
    end

    test "of GNU bash under 24h old, not yet patched, leaves the previous version's target",
         ctx do
      bash(ctx, "5.3", [{1, @old}, {2, @old}], {"5.4", hours_ago(2)})
      assert {out, 0} = toolchain(ctx, "check")
      assert out =~ "current: GNU bash 5.3.2"
    end

    test "of GNU bash 24h old, not yet patched, becomes the target", ctx do
      bash(ctx, "5.3", [{1, @old}, {2, @old}], {"5.4", @old})
      assert {out, 1} = toolchain(ctx, "check")
      assert out =~ "BLOCKED: GNU bash is pinned to 5.3.2; the target is 5.4.0"
    end

    test "in testing is never the target", ctx do
      github(ctx, "erlang/rebar3", [{"3.27.3", @old}, {"3.28.0", @old, true}])
      elixir(ctx, [{"1.20.4-otp-29", @old}, {"1.21.0-rc.0-otp-29", @old}])

      assert {_, 0} = toolchain(ctx, "check")
    end
  end

  describe "an advisory on the newest release 24h old" do
    setup ctx do
      github(ctx, "oven-sh/bun", [
        {"bun-v1.4.3", @old},
        {"bun-v1.4.4", hours_ago(3)},
        {"bun-v1.4.5", hours_ago(1)}
      ])
    end

    for range <- ["< 1.4.4", ">= 1.0, < 1.4.4", ">= 1.0.0 and < 1.4.4", "≥ 1.4.0-rc1 and < 1.4.4"] do
      test "makes the lowest newer release it does not cover the target (#{range})", ctx do
        repo_advisory(ctx, "oven-sh/bun", "bun", unquote(range))

        assert {out, 1} = toolchain(ctx, "check")

        assert out =~
                 "BLOCKED: bun is pinned to 1.4.3; the target is 1.4.4 (fixes an advisory on the newest release 24h old)"

        assert {_, 0} = toolchain(ctx, "bump")
        assert tools(ctx) =~ "\nbun 1.4.4\n"
      end
    end

    test "for another package leaves the target alone", ctx do
      repo_advisory(ctx, "oven-sh/bun", "bunx", "< 1.4.4")
      assert {_, 0} = toolchain(ctx, "check")
    end

    test "that is withdrawn leaves the target alone", ctx do
      repo_advisory(ctx, "oven-sh/bun", "bun", "< 1.4.4", "2026-01-01T00:00:00Z")
      assert {_, 0} = toolchain(ctx, "check")
    end

    test "with no release that fixes it leaves the target alone, noting the advisory", ctx do
      for range <- [
            ">= 1.0",
            ">= 0",
            ["< 0.9.0", ">= 0.9.0"],
            [">= 0.1", ">= 0.2"],
            [{"= 0.5.0", "0.5.1"}, ">= 0.6.0"]
          ] do
        repo_advisory(ctx, "oven-sh/bun", "bun", range)
        assert {out, 0} = toolchain(ctx, "check")
        assert out =~ "current: bun 1.4.3 (an advisory covers it; no release fixes it yet)"
      end
    end
  end

  test "an unfixed advisory on the newest release 24h old keeps a pin it does not cover", ctx do
    github(ctx, "oven-sh/bun", [
      {"bun-v1.4.3", @old},
      {"bun-v1.4.4", @old},
      {"bun-v1.4.5", hours_ago(1)}
    ])

    repo_advisory(ctx, "oven-sh/bun", "bun", ">= 1.4.4")

    assert {out, 0} = toolchain(ctx, "check")

    assert out =~
             "current: bun 1.4.3 (an advisory covers the newest release 24h old; no release fixes it yet)"

    assert {_, 0} = toolchain(ctx, "bump")
    assert tools(ctx) =~ "\nbun 1.4.3\n"
  end

  describe "an unfixed advisory on the newest release 24h old moves the pin there" do
    test "when it covers the pin too", ctx do
      File.write!(
        Path.join(ctx.base, ".tool-versions"),
        String.replace(tools(ctx), "bun 1.4.3", "bun 1.4.2")
      )

      github(ctx, "oven-sh/bun", [{"bun-v1.4.2", @old}, {"bun-v1.4.3", @old}])
      repo_advisory(ctx, "oven-sh/bun", "bun", ">= 1.0")

      assert {out, 1} = toolchain(ctx, "check")

      assert out =~
               "BLOCKED: bun is pinned to 1.4.2; the target is 1.4.3 (an advisory covers it; no release fixes it yet)"
    end

    test "unless a newer one 24h old is clean", ctx do
      File.write!(
        Path.join(ctx.base, ".tool-versions"),
        String.replace(tools(ctx), "bun 1.4.3", "bun 1.4.1")
      )

      github(ctx, "oven-sh/bun", [
        {"bun-v1.4.1", @old},
        {"bun-v1.4.2", @old},
        {"bun-v1.4.3", @old}
      ])

      repo_advisory(ctx, "oven-sh/bun", "bun", ">= 1.4.3")

      assert {out, 1} = toolchain(ctx, "check")

      assert out =~
               "BLOCKED: bun is pinned to 1.4.1; the target is 1.4.2 (an advisory covers the newest"
    end

    test "unless the pin is newer", ctx do
      File.write!(
        Path.join(ctx.base, ".tool-versions"),
        String.replace(tools(ctx), "bun 1.4.3", "bun 1.4.4")
      )

      github(ctx, "oven-sh/bun", [{"bun-v1.4.3", @old}, {"bun-v1.4.4", hours_ago(2)}])
      repo_advisory(ctx, "oven-sh/bun", "bun", [">= 1.4.0"])

      assert {out, 0} = toolchain(ctx, "check")
      assert out =~ "current: bun 1.4.4 (an advisory covers it; no release fixes it yet)"
    end

    test "when the pin is no longer a release", ctx do
      github(ctx, "oven-sh/bun", [{"bun-v1.4.4", @old}])
      repo_advisory(ctx, "oven-sh/bun", "bun", ">= 1.4.4")

      assert {out, 1} = toolchain(ctx, "check")
      assert out =~ "BLOCKED: bun is pinned to 1.4.3; the target is 1.4.4"
    end
  end

  # Erlang/OTP writes ranges with no upper bound, naming the fix on each
  # release line in patched_versions.
  describe "an Erlang/OTP advisory" do
    test "makes the young release that patches its line the target", ctx do
      otp(ctx, [{"29.1.2", @old}, {"29.1.3", hours_ago(2)}, {"29.2.0", hours_ago(1)}])

      otp_advisories(ctx, [
        [{">= 18.0", "29.1.3, 28.5.0.9, 27.3.4.20"}],
        [{">= 26.2.1", "26.2.5.12, 27.3.4"}, {">= 24.3.4.15", ""}],
        [{">= 17.0", "23.2.3"}]
      ])

      assert {out, 1} = toolchain(ctx, "check")

      assert out =~
               "BLOCKED: Erlang/OTP is pinned to 29.1.2; the target is 29.1.3 (fixes an advisory"

      assert {_, 0} = toolchain(ctx, "bump")
      assert tools(ctx) =~ "erlang 29.1.3\n"
      assert {_, 0} = toolchain(ctx, "check")
    end

    test "passes a release its line's patch or a newer line covers", ctx do
      otp(ctx, [{"29.1.2", @old}, {"29.1.3", hours_ago(1)}])

      otp_advisories(ctx, [
        [{">= 18.0", "29.1.2, 28.5.0.8"}],
        [{">= 26.2.1", "26.2.5.12, 27.3.4"}, {">= 24.3.4.15", ""}],
        [{">= 17.0", "23.2.3"}]
      ])

      assert {out, 0} = toolchain(ctx, "check")
      assert out =~ "current: Erlang/OTP 29.1.2\n"
    end

    test "with one open range and no patched version covers every newer line", ctx do
      otp(ctx, [{"29.1.2", @old}])
      otp_advisories(ctx, [[{">= 17.0", ""}]])

      assert {out, 0} = toolchain(ctx, "check")
      assert out =~ "current: Erlang/OTP 29.1.2 (an advisory covers it; no release fixes it yet)"
    end
  end

  test "an advisory on pnpm comes from GitHub's npm advisories", ctx do
    serve(
      ctx,
      "https://registry.npmjs.org/pnpm",
      Jason.encode!(%{
        "dist-tags" => %{"latest" => "12.11.3"},
        "time" => %{"12.11.2" => @old, "12.11.3" => hours_ago(2)}
      })
    )

    serve(
      ctx,
      "https://api.github.com/advisories?ecosystem=npm&affects=pnpm&per_page=100",
      advisories("pnpm", "< 12.11.3")
    )

    # pnpm checks its own release against minimumReleaseAge.
    File.write!(
      Path.join(ctx.base, "pnpm-young"),
      "pnpm@12.11.3\n@pnpm/exe.darwin-arm64@12.11.3\n"
    )

    assert {_, 0} = toolchain(ctx, "bump")
    assert File.read!(Path.join(ctx.base, "package.json")) =~ ~s("packageManager": "pnpm@12.11.3")

    assert File.read!(Path.join(ctx.base, "pnpm-workspace.yaml")) =~
             ~s(minimumReleaseAgeExclude:\n  - "pnpm@12.11.3"\n  - "@pnpm/exe.darwin-arm64@12.11.3"\n)

    assert File.read!(Path.join(ctx.base, "pnpm-log")) ==
             String.duplicate("pnpm install --lockfile-only --ignore-scripts\n", 2)
  end

  test "a pnpm bump re-locks pnpm", ctx do
    serve(
      ctx,
      "https://registry.npmjs.org/pnpm",
      Jason.encode!(%{
        "dist-tags" => %{"latest" => "12.14.0"},
        "time" => %{"12.11.2" => @old, "12.14.0" => @old}
      })
    )

    assert {_, 0} = toolchain(ctx, "bump")

    assert File.read!(Path.join(ctx.base, "pnpm-log")) ==
             "pnpm install --lockfile-only --ignore-scripts\n"

    assert File.read!(Path.join(ctx.base, "pnpm-workspace.yaml")) == "minimumReleaseAge: 1440\n"
  end

  test "a pin with a checksum gets the new release's checksum", ctx do
    github(ctx, "erlang/rebar3", [{"3.27.3", @old}, {"3.27.4", @old}])
    serve(ctx, "https://github.com/erlang/rebar3/releases/download/3.27.4/rebar3", "escript")

    assert {_, 0} = toolchain(ctx, "bump")
    sha = :crypto.hash(:sha256, "escript") |> Base.encode16(case: :lower)
    assert env(ctx) =~ "\nREBAR3_VERSION=3.27.4\nREBAR3_SHA256=#{sha}\n"
  end

  test "GNU bash's checksum covers the release and its patches in order", ctx do
    bash(ctx, "5.3", [{1, @old}, {2, @old}, {3, @old}])

    for {file, body} <-
          [{"bash-5.3.tar.gz", "tar"}, {"bash-5.3-patches/bash53-001", "p1"}] ++
            [{"bash-5.3-patches/bash53-002", "p2"}] do
      serve(ctx, "https://ftp.gnu.org/gnu/bash/" <> file, body)
    end

    # The newest patch's file answers the HEAD request too.
    serve(ctx, "https://ftp.gnu.org/gnu/bash/bash-5.3-patches/bash53-003", "p3")
    bash_date(ctx, "5.3", 3, @old, "p3")

    assert {_, 0} = toolchain(ctx, "bump")
    sha = :crypto.hash(:sha256, "tarp1p2" <> header(@old, "p3")) |> Base.encode16(case: :lower)
    assert env(ctx) =~ "\nGNU_BASH_VERSION=5.3.3\nGNU_BASH_SHA256=#{sha}\n"
  end

  test "Graphviz follows its GitLab releases and checksums the source tarball", ctx do
    graphviz(ctx, [{"16.2.0", hours_ago(2)}, {"16.1.1", @old}, {"16.1.0", @old}])

    serve(
      ctx,
      "https://gitlab.com/api/v4/projects/4207231/packages/generic/graphviz-releases/16.1.1/graphviz-16.1.1.tar.xz",
      "source"
    )

    assert {out, 1} = toolchain(ctx, "check")
    assert out =~ "BLOCKED: Graphviz is pinned to 16.1.0; the target is 16.1.1"

    assert {_, 0} = toolchain(ctx, "bump")
    sha = :crypto.hash(:sha256, "source") |> Base.encode16(case: :lower)
    assert env(ctx) =~ "\nGRAPHVIZ_VERSION=16.1.1\nGRAPHVIZ_SHA256=#{sha}\n"
  end

  test "OTP counts a release 24h old once both runners have its build", ctx do
    otp(ctx, [{"29.1.2", @old}, {"29.1.3", @old}], ["29.1.2"])
    assert {_, 0} = toolchain(ctx, "check")

    otp(ctx, [{"29.1.2", @old}, {"29.1.3", hours_ago(2)}])
    assert {_, 0} = toolchain(ctx, "check")
  end

  test "a rebuilt Erlang or Elixir release keeps its release date", ctx do
    # Every build the fixtures list is dated now.
    assert {out, 0} = toolchain(ctx, "check")
    assert out =~ "current: Erlang/OTP 29.1.2"
    assert out =~ "current: Elixir 1.20.4"
  end

  test "OTP stays on a major Elixir has no release 24h old built for", ctx do
    otp(ctx, [{"29.1.2", @old}, {"30.0", @old}])
    elixir(ctx, [{"1.20.4-otp-29", @old}, {"1.20.5-otp-30", hours_ago(2)}])

    assert {out, 0} = toolchain(ctx, "check")
    assert out =~ "current: Erlang/OTP 29.1.2"
  end

  test "Elixir follows the OTP major it moves to", ctx do
    otp(ctx, [{"29.1.2", @old}, {"30.0", @old}, {"30.0-rc1", @old}])
    elixir(ctx, [{"1.20.4-otp-29", @old}, {"1.20.4-otp-30", @old}, {"1.21.0-otp-29", @old}])

    assert {out, 0} = toolchain(ctx, "bump")
    assert out =~ "toolchain: Erlang/OTP 29.1.2 -> 30.0"
    assert tools(ctx) == "erlang 30.0\nelixir 1.20.4\nbun 1.4.3\n"
    assert {_, 0} = toolchain(ctx, "check")
  end

  describe "a workflow action" do
    test "moves to its newest release's commit in every workflow", ctx do
      github(ctx, "actions/checkout", [{"v7.0.1", @old}, {"v6.9.0", @old}, {"v7.1.0", @old}])
      commit(ctx, "actions/checkout", "v7.1.0", @checkout_next)

      assert {out, 1} = toolchain(ctx, "check")
      assert out =~ "BLOCKED: actions/checkout is pinned to v7.0.1; the target is v7.1.0"

      assert {_, 0} = toolchain(ctx, "bump")

      for file <- ~w(ci.yml audit.yml) do
        assert File.read!(Path.join(ctx.base, ".github/workflows/" <> file)) =~
                 "uses: actions/checkout@#{@checkout_next} # v7.1.0\n"
      end
    end

    test "pinned to a commit other than its tag's blocks, and the bump repins it", ctx do
      commit(ctx, "actions/checkout", "v7.0.1", @checkout_next)

      assert {out, 1} = toolchain(ctx, "check")
      assert out =~ "BLOCKED: actions/checkout v7.0.1: #{@checkout_sha} is not v7.0.1's commit"

      assert {_, 0} = toolchain(ctx, "bump")
      assert {_, 0} = toolchain(ctx, "check")
    end

    test "takes its advisories from GitHub's actions advisories", ctx do
      github(ctx, "actions/checkout", [{"v7.0.1", @old}, {"v7.0.2", hours_ago(1)}])
      commit(ctx, "actions/checkout", "v7.0.2", @checkout_next)

      serve(
        ctx,
        "https://api.github.com/advisories?ecosystem=actions&affects=actions%2Fcheckout&per_page=100",
        advisories("actions/checkout", "< 7.0.2")
      )

      assert {out, 1} = toolchain(ctx, "check")
      assert out =~ "the target is v7.0.2 (fixes an advisory"
    end

    for uses <- ["actions/checkout@v7", "actions/checkout@#{String.duplicate("c", 40)}"] do
      test "without a commit and tag pin fails closed (#{uses})", ctx do
        File.write!(
          Path.join(ctx.base, ".github/workflows/ci.yml"),
          "    - uses: #{unquote(uses)}\n"
        )

        assert {out, 2} = toolchain(ctx, "check")
        assert out =~ "each remote action needs one `owner/repo@<sha> # <tag>` pin"
      end
    end
  end

  test "a feed it cannot read fails closed", ctx do
    File.rm!(fixture(ctx, "https://builds.hex.pm/builds/elixir/builds.txt"))

    for mode <- ~w(check bump) do
      assert {out, 2} = toolchain(ctx, mode)
      assert out =~ "builds.hex.pm/builds/elixir/builds.txt"
      assert out =~ "cannot check the toolchain"
    end

    assert File.read!(Path.join(ctx.base, ".github/toolchain.env")) == @env
  end

  test "an advisory feed it cannot read fails closed", ctx do
    url =
      "https://api.github.com/repos/oven-sh/bun/security-advisories?state=published&per_page=100"

    for body <- [~s({"message": "Not Found"}), "not json"] do
      serve(ctx, url, body)
      assert {out, 2} = toolchain(ctx, "check")
      assert out =~ "cannot check the toolchain"
    end
  end

  test "a pin on a release under 24h old is moved back to the target", ctx do
    github(ctx, "oven-sh/bun", [{"bun-v1.4.3", @old}, {"bun-v1.4.4", hours_ago(2)}])

    File.write!(
      Path.join(ctx.base, ".tool-versions"),
      "erlang 29.1.2\nelixir 1.20.4\nbun 1.4.4\n"
    )

    assert {out, 1} = toolchain(ctx, "check")
    assert out =~ "BLOCKED: bun is pinned to 1.4.4; the target is 1.4.3"

    assert {_, 0} = toolchain(ctx, "bump")
    assert tools(ctx) =~ "\nbun 1.4.3\n"
  end

  test "a source with no release 24h old fails closed", ctx do
    github(ctx, "hexpm/hex", [{"v2.5.3", hours_ago(1)}])
    assert {out, 2} = toolchain(ctx, "check")
    assert out =~ "Hex: no release is 24h old"
  end

  test "an unknown mode is refused", ctx do
    assert {out, 2} = toolchain(ctx, "fix")
    assert out =~ "usage: bun scripts/toolchain.ts check|bump"
  end

  # ------------------------------------------------------------- fixtures

  defp hours_ago(h),
    do: DateTime.utc_now() |> DateTime.add(-h, :hour) |> DateTime.to_iso8601()

  defp fixture(ctx, url), do: Path.join(ctx.web, String.replace(url, ~r/[^A-Za-z0-9]/, "_"))

  defp serve(ctx, url, body), do: File.write!(fixture(ctx, url), body)

  defp github(ctx, repo, releases) do
    serve(
      ctx,
      "https://api.github.com/repos/#{repo}/releases?per_page=100",
      Jason.encode!(
        for release <- releases do
          {tag, at, pre} =
            case release do
              {tag, at} -> {tag, at, false}
              {tag, at, pre} -> {tag, at, pre}
            end

          %{"tag_name" => tag, "published_at" => at, "draft" => false, "prerelease" => pre}
        end
      )
    )
  end

  defp commit(ctx, repo, tag, sha),
    do: serve(ctx, "https://api.github.com/repos/#{repo}/commits/#{tag}", ~s({"sha": "#{sha}"}))

  # OTP RELEASES on GitHub, each built for both runners, or for Ubuntu
  # only those UBUNTU lists. Each build is dated now, as a rebuild would.
  defp otp(ctx, releases, ubuntu \\ nil) do
    versions = Enum.map(releases, &elem(&1, 0))
    github(ctx, "erlang/otp", for({v, at} <- releases, do: {"OTP-#{v}", at}))

    serve(
      ctx,
      "https://raw.githubusercontent.com/erlef/otp_builds/refs/heads/main/builds/aarch64-apple-darwin.csv",
      "ref_name,ref,datetime,sha256\nmaster,abc,#{@old},def\n" <>
        Enum.map_join(versions, &"OTP-#{&1},abc,#{hours_ago(0)},def\n")
    )

    serve(
      ctx,
      "https://builds.hex.pm/builds/otp/ubuntu-24.04/builds.txt",
      Enum.map_join(ubuntu || versions, &"OTP-#{&1} abc #{hours_ago(0)} def\n")
    )
  end

  defp graphviz(ctx, releases) do
    serve(
      ctx,
      "https://gitlab.com/api/v4/projects/4207231/releases?per_page=100",
      Jason.encode!(
        for {tag, at} <- releases,
            do: %{"tag_name" => tag, "released_at" => at, "upcoming_release" => false}
      )
    )
  end

  # Elixir BUILDS, "version-otp-major", each released on GitHub at its
  # date and built now, as a rebuild would.
  defp elixir(ctx, builds) do
    github(
      ctx,
      "elixir-lang/elixir",
      builds
      |> Enum.map(fn {build, at} -> {"v" <> hd(String.split(build, "-otp-")), at} end)
      |> Enum.uniq_by(&elem(&1, 0))
    )

    serve(
      ctx,
      "https://builds.hex.pm/builds/elixir/builds.txt",
      Enum.map_join(builds, &"v#{elem(&1, 0)} abc #{hours_ago(0)} def \n")
    )
  end

  # Lists bash BASE and its patches, each patch's file answering the HEAD
  # request with its Last-Modified date. With UNPATCHED, also lists that
  # newer version, released AT with no patches directory yet.
  defp bash(ctx, base, patches, unpatched \\ nil) do
    [major, minor] = String.split(base, ".")

    newer =
      case unpatched do
        {version, at} ->
          serve(ctx, "https://ftp.gnu.org/gnu/bash/bash-#{version}.tar.gz", header(at, ""))
          ~s(<a href="bash-#{version}.tar.gz">x</a>)

        nil ->
          ""
      end

    serve(
      ctx,
      "https://ftp.gnu.org/gnu/bash/",
      ~s(<a href="bash-5.2.tar.gz">x</a><a href="bash-#{base}.tar.gz">x</a>) <>
        ~s(<a href="bash-#{base}-patches/">x</a><a href="bash-6.0-rc1.tar.gz">x</a>) <> newer
    )

    serve(
      ctx,
      "https://ftp.gnu.org/gnu/bash/bash-#{base}-patches/",
      Enum.map_join(patches, fn {n, _} ->
        ~s(<a href="bash#{major}#{minor}-#{String.pad_leading("#{n}", 3, "0")}">x</a>)
      end)
    )

    for {n, at} <- patches, do: bash_date(ctx, base, n, at, "")
  end

  defp bash_date(ctx, base, n, at, _body) do
    [major, minor] = String.split(base, ".")
    file = "bash#{major}#{minor}-#{String.pad_leading("#{n}", 3, "0")}"
    serve(ctx, "https://ftp.gnu.org/gnu/bash/bash-#{base}-patches/#{file}", header(at, ""))
  end

  defp header(at, _body) do
    {:ok, dt, _} = DateTime.from_iso8601(at)
    "HTTP/2 200\r\nlast-modified: #{Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")}\r\n\r\n"
  end

  # One advisory, with a row for each of RANGES: a range or a list of
  # ranges and {range, patched_versions} pairs.
  defp repo_advisory(ctx, repo, name, ranges, withdrawn \\ nil) do
    serve(
      ctx,
      "https://api.github.com/repos/#{repo}/security-advisories?state=published&per_page=100",
      Jason.encode!([
        %{
          "withdrawn_at" => withdrawn,
          "vulnerabilities" =>
            for row <- List.wrap(ranges) do
              {range, patched} = with range when is_binary(range) <- row, do: {range, nil}

              %{
                "package" => %{"name" => name},
                "vulnerable_version_range" => range,
                "patched_versions" => patched
              }
            end
        }
      ])
    )
  end

  # Each advisory is a list of {range, patched_versions} rows for OTP.
  defp otp_advisories(ctx, advisories) do
    serve(
      ctx,
      "https://api.github.com/repos/erlang/otp/security-advisories?state=published&per_page=100",
      Jason.encode!(
        for rows <- advisories do
          %{
            "vulnerabilities" =>
              for {range, patched} <- rows do
                %{
                  "package" => %{"name" => "OTP"},
                  "vulnerable_version_range" => range,
                  "patched_versions" => patched
                }
              end
          }
        end
      )
    )
  end

  defp advisories(name, range),
    do:
      Jason.encode!([
        %{
          "vulnerabilities" => [
            %{"package" => %{"name" => name}, "vulnerable_version_range" => range}
          ]
        }
      ])

  defp env(ctx), do: File.read!(Path.join(ctx.base, ".github/toolchain.env"))

  defp tools(ctx), do: File.read!(Path.join(ctx.base, ".tool-versions"))

  defp toolchain(ctx, mode) do
    System.cmd("bun", [@script, mode],
      cd: ctx.base,
      env: [{"PATH", ctx.path}, {"GITHUB_TOKEN", "t0k"}],
      stderr_to_stdout: true
    )
  end
end
