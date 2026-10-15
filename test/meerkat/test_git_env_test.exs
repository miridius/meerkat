defmodule Meerkat.TestGitEnvTest do
  # Git starts a detached `git maintenance run --auto` after a commit and in
  # receive-pack; one still writing into a fixture repo when its on_exit
  # removes the repo makes File.rm_rf! fail. No git a test starts may run it.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, stage: 3]

  setup do
    base = Meerkat.TestHelpers.tmp_path("meerkat-git-env")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  test "git started by a test runs no auto maintenance on commit or push", %{base: base} do
    work = Path.join(base, "work")
    remote = Path.join(base, "remote.git")
    trace = Path.join(base, "trace")
    File.mkdir_p!(work)
    git(base, ["init", "-q", "--bare", remote])
    git(work, ["init", "-q", "--initial-branch=main"])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])
    stage(work, "a.txt", "a\n")

    Meerkat.TestHelpers.put_env("GIT_TRACE2_EVENT", trace)
    git(work, ["commit", "-qm", "a"])
    git(work, ["push", "-q", remote, "main"])

    events = trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    started = for %{"event" => "child_start", "argv" => argv} <- events, do: argv
    # Here only receive-pack starts unpack-objects (the push is under
    # receive.unpackLimit), so its children are traced.
    assert Enum.any?(started, &match?(["git", "unpack-objects" | _], &1))
    assert Enum.filter(started, &("maintenance" in &1 or "gc" in &1)) == []
  end

  # So the caller's signing, hooks or diff settings never reach a fixture.
  test "git started by a test reads no config but the tests' global config", %{base: base} do
    Meerkat.TestHelpers.put_env("GIT_CONFIG_PARAMETERS", "'meerkat.injected'='1'")
    Meerkat.TestHelpers.put_env("GIT_CONFIG_COUNT", "1")
    Meerkat.TestHelpers.put_env("GIT_CONFIG_KEY_0", "meerkat.counted")
    Meerkat.TestHelpers.put_env("GIT_CONFIG_VALUE_0", "1")
    Meerkat.TestHelpers.put_git_config_env()

    assert git(base, ["config", "--list", "--show-scope"]) == "global\tmaintenance.auto=false"
  end
end
