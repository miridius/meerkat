defmodule Meerkat.ToolchainTest do
  # Runs the repo's real scripts/toolchain.ts against pins each test
  # writes, testing the seams scripts/toolchain.test.ts leaves out: curl,
  # pnpm and the files on disk. Only curl, gh and pnpm are replaced, by
  # stubs on PATH: curl serves the file a test wrote for a URL, or for that
  # read of it, `[]` for any other GitHub API URL, and fails for the rest,
  # or for a read a test cancels. A test can also have it hang on a URL, or
  # wait up to 10 s for a file to exist before answering a URL.
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

  @action """
  runs:
    using: composite
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
    File.mkdir_p!(Path.join(base, "tmp"))
    File.mkdir_p!(Path.join(base, ".github/workflows"))

    File.write!(Path.join(base, ".github/toolchain.env"), @env)
    File.write!(Path.join(base, ".tool-versions"), @tool_versions)
    File.write!(Path.join(base, ".github/workflows/ci.yml"), @ci)
    File.write!(Path.join(base, ".github/workflows/audit.yml"), @audit)
    File.mkdir_p!(Path.join(base, ".github/actions/toolchain"))
    File.write!(Path.join(base, ".github/actions/toolchain/action.yml"), @action)

    File.write!(
      Path.join(base, "package.json"),
      ~s({\n  "name": "x",\n  "packageManager": "pnpm@12.11.2"\n}\n)
    )

    File.write!(Path.join(stubs, "curl"), """
    #!/usr/bin/env bash
    cat >> '#{base}/curl-config'
    echo "$*" >> '#{base}/curl-args'
    url="${@: -1}"
    exec > "${@: -2:1}"
    f='#{web}'/"$(printf %s "$url" | tr -c 'A-Za-z0-9' '_')"
    if [[ -e "$f.hang" ]]; then echo $$ > "$f.pid"; exec sleep 60; fi
    if [[ -e "$f.after" ]]; then
      for _ in {1..200}; do [[ -e "$(cat "$f.after")" ]] && break; sleep 0.05; done
    fi
    # A URL's reads are counted once a test counts them.
    if [[ -e "$f.reads" ]]; then
      read=$(( $(cat "$f.reads") + 1 ))
      echo "$read" > "$f.reads"
    fi
    if [[ -n "$read" && -e "$f.$read.cancel" ]]; then
      echo 'curl: (92) HTTP/2 stream 1 was not closed cleanly: CANCEL (err 8)' >&2; exit 92
    elif [[ -n "$read" && -e "$f.$read" ]]; then cat "$f.$read"
    elif [[ -e "$f" ]]; then cat "$f"
    elif [[ "$url" == https://api.github.com/* ]]; then echo '[]'
    else printf 'curl: (28) slow\\ncurl: (22) 404 %s\\nMore details here\\n' "$url" >&2; exit 22; fi
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

  test "pins on their targets pass the check, asking curl with GITHUB_TOKEN on stdin", ctx do
    assert {out, 0} = toolchain(ctx, "check")
    assert out =~ "current: bun 1.4.3"
    assert out =~ "current: GNU bash 5.3.2"
    assert out =~ "current: actions/checkout v7.0.1"
    assert File.read!(Path.join(ctx.base, "curl-config")) =~ "Authorization: Bearer t0k"
    # curl retries each request's transient failures.
    requests = File.read!(Path.join(ctx.base, "curl-args")) |> String.split("\n", trim: true)
    assert requests != []
    assert Enum.all?(requests, &(&1 =~ " --retry 3 "))
    assert File.ls!(Path.join(ctx.base, "tmp")) == []
  end

  test "tries a request again after a cancelled HTTP/2 stream, three times at most", ctx do
    url = "https://api.github.com/repos/oven-sh/bun/releases?per_page=100"
    for read <- 1..3, do: cancel(ctx, url, read)
    assert {_, 0} = toolchain(ctx, "check")
    assert reads(ctx, url) == 4
    assert File.ls!(Path.join(ctx.base, "tmp")) == []

    for read <- 5..8, do: cancel(ctx, url, read)
    assert {out, 2} = toolchain(ctx, "check")
    assert out =~ "#{url}: curl: (92) HTTP/2 stream 1 was not closed cleanly"
    assert reads(ctx, url) == 8
  end

  test "a bump writes the new release and its checksum", ctx do
    github(ctx, "erlang/rebar3", [{"3.27.3", @old}, {"3.27.4", @old}])
    serve(ctx, "https://github.com/erlang/rebar3/releases/download/3.27.4/rebar3", "escript")

    assert {out, 0} = toolchain(ctx, "bump")
    assert out =~ "pre-commit: toolchain: rebar3 3.27.3 -> 3.27.4"
    sha = :crypto.hash(:sha256, "escript") |> Base.encode16(case: :lower)
    assert env(ctx) =~ "\nREBAR3_VERSION=3.27.4\nREBAR3_SHA256=#{sha}\n"
    assert {_, 0} = toolchain(ctx, "check")
  end

  test "a pnpm bump re-locks pnpm, excluding each young part pnpm refuses", ctx do
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

  test "a feed it cannot read fails closed, showing only curl's last error", ctx do
    builds = "https://builds.hex.pm/builds/elixir/builds.txt"
    File.rm!(fixture(ctx, builds))
    count_reads(ctx, builds)

    for mode <- ~w(check bump) do
      assert {out, 2} = toolchain(ctx, mode)
      assert out =~ "builds.hex.pm/builds/elixir/builds.txt: curl: (22) 404"
      refute out =~ "slow"
      refute out =~ "More details"
      assert out =~ "cannot check the toolchain"
      assert File.ls!(Path.join(ctx.base, "tmp")) == []
    end

    assert reads(ctx, builds) == 2
    assert File.read!(Path.join(ctx.base, ".github/toolchain.env")) == @env
  end

  test "a failed request stops the requests still in flight", ctx do
    hang = fixture(ctx, "https://api.github.com/repos/oven-sh/bun/releases?per_page=100")
    File.write!(hang <> ".hang", "")
    builds = fixture(ctx, "https://builds.hex.pm/builds/elixir/builds.txt")
    File.rm!(builds)
    File.write!(builds <> ".after", hang <> ".pid")

    assert {_, 2} = toolchain(ctx, "check")
    assert File.ls!(Path.join(ctx.base, "tmp")) == []
    pid = (hang <> ".pid") |> File.read!() |> String.trim()

    assert Meerkat.TestHelpers.eventually(
             fn -> elem(System.cmd("kill", ["-0", pid], stderr_to_stdout: true), 1) != 0 end,
             interval: 100
           )
  end

  # ------------------------------------------------------------- fixtures

  defp hours_ago(h),
    do: DateTime.utc_now() |> DateTime.add(-h, :hour) |> DateTime.to_iso8601()

  defp fixture(ctx, url), do: Path.join(ctx.web, String.replace(url, ~r/[^A-Za-z0-9]/, "_"))

  defp serve(ctx, url, body), do: File.write!(fixture(ctx, url), body)

  # Has the READth read of URL end in a cancelled HTTP/2 stream.
  defp cancel(ctx, url, read) do
    count_reads(ctx, url)
    File.write!("#{fixture(ctx, url)}.#{read}.cancel", "")
  end

  defp count_reads(ctx, url) do
    counter = fixture(ctx, url) <> ".reads"
    unless File.exists?(counter), do: File.write!(counter, "0")
  end

  defp reads(ctx, url),
    do: File.read!(fixture(ctx, url) <> ".reads") |> String.trim() |> String.to_integer()

  defp github(ctx, repo, releases) do
    serve(
      ctx,
      "https://api.github.com/repos/#{repo}/releases?per_page=100",
      releases_json(releases)
    )
  end

  defp releases_json(releases) do
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

  defp toolchain(ctx, mode) do
    System.cmd("bun", [@script, mode],
      cd: ctx.base,
      env: [
        {"PATH", ctx.path},
        {"GITHUB_TOKEN", "t0k"},
        {"TMPDIR", Path.join(ctx.base, "tmp")}
      ],
      stderr_to_stdout: true
    )
  end
end
