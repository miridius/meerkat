defmodule Meerkat.HexAuditTest do
  # Runs the repo's real scripts/hex-audit.ts. Only mix is replaced, by a
  # stub on PATH that prints what a test sets up and exits with its code.
  use ExUnit.Case, async: true

  @script Path.join(File.cwd!(), "scripts/hex-audit.ts")

  setup do
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-hex-audit")
    on_exit(fn -> File.rm_rf!(base) end)

    stubs = Path.join(base, "stubs")
    File.mkdir_p!(stubs)
    mix = Path.join(stubs, "mix")

    File.write!(mix, """
    #!/usr/bin/env bash
    [[ "$*" == "hex.audit" ]] || exit 99
    cat '#{base}/out'
    cat '#{base}/err' >&2
    exit "$(cat '#{base}/code')"
    """)

    File.chmod!(mix, 0o755)
    %{base: base, path: stubs <> ":" <> System.get_env("PATH")}
  end

  defp audit(ctx, out, err, code) do
    File.write!(Path.join(ctx.base, "out"), out)
    File.write!(Path.join(ctx.base, "err"), err)
    File.write!(Path.join(ctx.base, "code"), Integer.to_string(code))

    System.cmd("bun", [@script],
      cd: ctx.base,
      env: [{"PATH", ctx.path}],
      stderr_to_stdout: true
    )
  end

  test "passes a clean audit and shows its output", ctx do
    assert {out, 0} = audit(ctx, "No retired or security advisory packages found\n", "", 0)
    assert out =~ "No retired or security advisory packages found"
  end

  test "fails when mix hex.audit fails", ctx do
    assert {out, 1} = audit(ctx, "Found retired packages\n", "", 1)
    assert out =~ "Found retired packages"
  end

  test "fails a passing audit when Hex could not fetch a record", ctx do
    err = "Failed to fetch record for bandit from registry (using cache instead)\n"

    assert {out, 1} =
             audit(ctx, "No retired or security advisory packages found\n", err, 0)

    assert out =~ "Failed to fetch record for bandit"
    assert out =~ "the audit is incomplete"
  end
end
