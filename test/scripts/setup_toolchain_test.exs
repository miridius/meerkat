defmodule Meerkat.SetupToolchainTest do
  # Runs the repo's real scripts/setup-toolchain.ts against pins each test
  # writes. elixir, mix and curl are replaced by stubs on PATH: elixir
  # names an archives dir and rebar3 path in the scratch dir, mix logs
  # each run, and curl downloads the `rebar3-download` file.
  use ExUnit.Case, async: true

  @script Path.join(File.cwd!(), "scripts/setup-toolchain.ts")

  @rebar "rebar3 build\n"

  setup do
    base = Meerkat.TestHelpers.tmp_path("meerkat-setup-toolchain")
    on_exit(fn -> File.rm_rf!(base) end)

    stubs = Path.join(base, "stubs")
    archives = Path.join(base, "archives")
    File.mkdir_p!(stubs)
    File.mkdir_p!(archives)
    File.mkdir_p!(Path.join(base, ".github"))

    File.write!(Path.join(base, ".github/toolchain.env"), """
    HEX_VERSION=2.5.3
    REBAR3_VERSION=3.27.3
    REBAR3_SHA256=#{sha256(@rebar)}
    """)

    File.write!(Path.join(base, "rebar3-download"), @rebar)

    File.write!(Path.join(stubs, "elixir"), """
    #!/usr/bin/env bash
    printf '%s\\n%s\\n' '#{archives}' '#{base}/rebar3'
    """)

    File.write!(Path.join(stubs, "mix"), """
    #!/usr/bin/env bash
    echo "mix $*" >> '#{base}/log'
    [[ "$1" == local.rebar ]] && echo "got $(cat "$3")" >> '#{base}/log'
    exit 0
    """)

    File.write!(Path.join(stubs, "curl"), """
    #!/usr/bin/env bash
    echo "curl ${@: -1}" >> '#{base}/log'
    cp '#{base}/rebar3-download' "$2"
    """)

    for stub <- ~w(elixir mix curl), do: File.chmod!(Path.join(stubs, stub), 0o755)

    %{base: base, archives: archives, path: stubs <> ":" <> System.fetch_env!("PATH")}
  end

  test "a fresh Elixir gets the pinned Hex and the checked rebar3", ctx do
    assert {_, 0} = setup_toolchain(ctx)

    assert [
             "mix local.hex 2.5.3 --force",
             "curl https://github.com/erlang/rebar3/releases/download/3.27.3/rebar3",
             install,
             "got rebar3 build"
           ] = log(ctx)

    assert install =~ ~r"^mix local.rebar rebar3 \S+/rebar3 --force$"
  end

  test "installs nothing when both are in place", ctx do
    File.mkdir_p!(Path.join(ctx.archives, "hex-2.5.3"))
    File.write!(Path.join(ctx.base, "rebar3"), @rebar)

    assert {_, 0} = setup_toolchain(ctx)
    refute File.exists?(Path.join(ctx.base, "log"))
  end

  test "an installed rebar3 that differs from the pin is replaced", ctx do
    File.mkdir_p!(Path.join(ctx.archives, "hex-2.5.3"))
    File.write!(Path.join(ctx.base, "rebar3"), "older rebar3\n")

    assert {_, 0} = setup_toolchain(ctx)
    assert Enum.at(log(ctx), 2) == "got rebar3 build"
  end

  test "a download that differs from the pin is refused", ctx do
    File.write!(Path.join(ctx.base, "rebar3-download"), "tampered\n")

    assert {out, 1} = setup_toolchain(ctx)
    assert out =~ "rebar3 3.27.3 hashes to #{sha256("tampered\n")}, not #{sha256(@rebar)}."
    refute Enum.any?(log(ctx), &(&1 =~ "local.rebar"))
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp log(ctx),
    do: ctx.base |> Path.join("log") |> File.read!() |> String.split("\n", trim: true)

  defp setup_toolchain(ctx) do
    System.cmd("bun", [@script], cd: ctx.base, env: [{"PATH", ctx.path}], stderr_to_stdout: true)
  end
end
