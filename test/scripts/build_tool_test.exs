defmodule Meerkat.BuildToolTest do
  # Runs the repo's real scripts/build-tool.ts with curl, tar, patch and
  # make replaced by stubs on PATH that log each call; curl writes "tarball"
  # for every download.
  use ExUnit.Case, async: true

  @script Path.join(File.cwd!(), "scripts/build-tool.ts")

  setup do
    base = Meerkat.TestHelpers.tmp_path("meerkat-build-tool")
    on_exit(fn -> File.rm_rf!(base) end)
    stubs = Path.join(base, "stubs")
    File.mkdir_p!(stubs)

    File.write!(Path.join(stubs, "stub"), """
    #!/usr/bin/env bash
    echo "$(basename "$0") $*" >> '#{base}/log'
    if [[ "$(basename "$0")" == curl ]]; then printf tarball > "${@: -2:1}"; fi
    """)

    File.chmod!(Path.join(stubs, "stub"), 0o755)
    for tool <- ~w(curl tar patch make), do: File.ln_s!("stub", Path.join(stubs, tool))

    %{base: base, path: stubs <> ":" <> System.fetch_env!("PATH")}
  end

  test "a download that does not match its pinned checksum builds nothing", ctx do
    assert {out, 1} =
             System.cmd("bun", [@script, "graphviz", Path.join(ctx.base, "prefix")],
               env: [
                 {"PATH", ctx.path},
                 {"GRAPHVIZ_VERSION", "16.1.0"},
                 {"GRAPHVIZ_SHA256", String.duplicate("0", 64)}
               ],
               stderr_to_stdout: true
             )

    sha = :crypto.hash(:sha256, "tarball") |> Base.encode16(case: :lower)
    assert out =~ "graphviz 16.1.0 hashes to #{sha}, not #{String.duplicate("0", 64)}."

    assert [curl] = ctx.base |> Path.join("log") |> File.read!() |> String.split("\n", trim: true)
    assert curl =~ "graphviz-releases/16.1.0/graphviz-16.1.0.tar.xz"
  end
end
