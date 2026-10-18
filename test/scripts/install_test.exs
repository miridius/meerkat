defmodule Meerkat.InstallScriptTest do
  # Runs the repo's real scripts/install.sh from a committed, clean
  # checkout whose commit `current` already holds. A stub `mix` first on
  # PATH records a run and fails, so a rebuild is detected without
  # building anything.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2]

  @root File.cwd!()

  setup do
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-install")
    on_exit(fn -> File.rm_rf!(base) end)
    File.rm_rf!(Path.join(base, ".git"))

    repo = Path.join(base, "repo")
    share = Path.join(base, "share")
    bin = Path.join(base, "bin")
    shim = Path.join(base, "shim")
    marker = Path.join(base, "mix-ran")

    File.mkdir_p!(Path.join(repo, "scripts"))
    File.cp!(Path.join(@root, "scripts/install.sh"), Path.join(repo, "scripts/install.sh"))
    git(repo, ["init", "-q"])
    git(repo, ["add", "."])
    git(repo, ["-c", "user.email=t@t.t", "-c", "user.name=t", "commit", "-q", "-m", "base"])
    head = git(repo, ["rev-parse", "HEAD"])

    version = Path.join([share, "versions", "v1"])
    executable(Path.join([version, "bin", "meerkat"]), "#!/bin/sh\n")
    File.write!(Path.join(version, "INSTALLED_COMMIT"), head <> "\n")
    File.ln_s!(version, Path.join(share, "current"))
    executable(Path.join(share, "meerkat-shepherd"), "#!/bin/sh\n")
    File.write!(Path.join(share, "meerkat-attach"), "")
    executable(Path.join(shim, "mix"), "#!/bin/sh\ntouch '#{marker}'\nexit 99\n")
    # The toolchain setup ahead of the build.
    for tool <- ~w(mise bun), do: executable(Path.join(shim, tool), "#!/bin/sh\n")

    env = [
      {"PATH", shim <> ":" <> System.get_env("PATH")},
      {"MEERKAT_INSTALL_PREFIX", share},
      {"MEERKAT_BIN_DIR", bin}
    ]

    {:ok, repo: repo, share: share, launcher: Path.join(bin, "meerkat"), marker: marker, env: env}
  end

  test "skips the rebuild when the prod launcher is installed", ctx do
    executable(ctx.launcher, prod_launcher(ctx))

    assert {out, 0} = install(ctx)
    assert out =~ "skipping"
    refute File.exists?(ctx.marker)
  end

  test "rebuilds when a dev launcher is installed, so it gets replaced", ctx do
    executable(
      ctx.launcher,
      "#!/usr/bin/env bash\n# meerkat dev launcher (installed by scripts/dev-install.sh)\n"
    )

    assert {_, status} = install(ctx)
    assert status != 0
    assert File.exists?(ctx.marker)
  end

  describe "a rebuild with mise" do
    setup ctx do
      executable(ctx.launcher, "#!/bin/sh\n")
      shim = Path.join(Path.dirname(ctx.share), "shim")
      pinned = Path.join(Path.dirname(ctx.share), "pinned")
      pinned_marker = Path.join(pinned, "mix-ran")
      executable(Path.join(pinned, "mix"), "#!/bin/sh\ntouch '#{pinned_marker}'\nexit 99\n")
      %{mise: Path.join(shim, "mise"), pinned: pinned, pinned_marker: pinned_marker}
    end

    test "builds on the tools mise pins", ctx do
      executable(
        ctx.mise,
        ~s(#!/bin/sh\n[ "$1" = env ] && echo 'export PATH="#{ctx.pinned}:$PATH"'\nexit 0\n)
      )

      assert {_, status} = install(ctx)
      assert status != 0
      assert File.exists?(ctx.pinned_marker)
      refute File.exists?(ctx.marker)
    end

    test "stops when mise cannot give its environment", ctx do
      executable(ctx.mise, ~s(#!/bin/sh\n[ "$1" = env ] && exit 3\nexit 0\n))

      assert {_, 3} = install(ctx)
      refute File.exists?(ctx.pinned_marker)
      refute File.exists?(ctx.marker)
    end
  end

  defp install(ctx) do
    System.cmd("bash", [Path.join(ctx.repo, "scripts/install.sh")],
      env: ctx.env,
      stderr_to_stdout: true
    )
  end

  # The launcher install.sh writes, from its own `launcher` function.
  defp prod_launcher(ctx) do
    script = ~S"""
    eval "$(sed -n '/^launcher() {/,/^}/p' "$1")"
    CURRENT_LINK="$2" SHEPHERD_DEST="$3" launcher
    """

    {out, 0} =
      System.cmd("bash", [
        "-c",
        script,
        "bash",
        Path.join(ctx.repo, "scripts/install.sh"),
        Path.join(ctx.share, "current"),
        Path.join(ctx.share, "meerkat-shepherd")
      ])

    assert out =~ "installed by scripts/install.sh"
    out
  end

  defp executable(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end
end
