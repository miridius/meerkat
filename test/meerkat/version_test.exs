defmodule Meerkat.VersionTest do
  # async: false: RELEASE_ROOT is process-global env.
  use Meerkat.Case, async: false

  import ExUnit.CaptureLog

  alias Meerkat.Version

  setup do
    prev = System.get_env("RELEASE_ROOT")

    on_exit(fn ->
      if prev, do: System.put_env("RELEASE_ROOT", prev), else: System.delete_env("RELEASE_ROOT")
    end)

    :ok
  end

  defp with_manifest(lines) do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-ver")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "meerkat_version"), Enum.join(lines, "\n") <> "\n")
    System.put_env("RELEASE_ROOT", dir)
    on_exit(fn -> File.rm_rf!(dir) end)
  end

  test "parses the baked manifest into a label and changelog" do
    with_manifest([
      "2b4dd74ce4c3abc",
      "https://github.com/miridius/meerkat",
      "Live-restart a review onto a newly-installed version (#11)",
      "Install versioned releases (#10)",
      "a direct commit with no PR ref"
    ])

    info = Version.info()

    refute info.dev?
    assert info.label == "2b4dd74"

    assert info.changelog == [
             %{
               number: 11,
               title: "Live-restart a review onto a newly-installed version",
               url: "https://github.com/miridius/meerkat/pull/11"
             },
             %{
               number: 10,
               title: "Install versioned releases",
               url: "https://github.com/miridius/meerkat/pull/10"
             }
           ]
  end

  test "drops the PR link when no origin remote is baked in" do
    with_manifest(["abc1234", "", "Some change (#5)"])

    assert [%{number: 5, title: "Some change", url: nil}] = Version.info().changelog
  end

  test "falls back to dev info without a release root" do
    System.delete_env("RELEASE_ROOT")

    log = capture_log(fn -> send(self(), {:info, Version.info()}) end)
    assert_received {:info, info}

    assert log == "", "a dev tree expects no manifest, so its absence is not warned about"
    assert info.dev?
    assert info.changelog == []
    assert info.label == "dev: " <> Version.dev_branch(Version.source_root())
  end

  test "a dev build reports the source tree it runs from" do
    assert Version.source_root() == File.cwd!()
  end

  describe "dev_branch/1" do
    setup do
      dir = Meerkat.TestHelpers.tmp_path("meerkat-ver-branch")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "is the checked-out branch", %{dir: dir} do
      Meerkat.TestHelpers.git(dir, ["init", "-q", "-b", "feat/x"])
      assert Version.dev_branch(dir) == "feat/x"
    end

    test "is unknown on a detached HEAD", %{dir: dir} do
      Meerkat.TestHelpers.git(dir, ["init", "-q", "-b", "main"])
      Meerkat.TestHelpers.commit(dir, "one")
      Meerkat.TestHelpers.git(dir, ["checkout", "-q", "--detach"])
      assert Version.dev_branch(dir) == "unknown"
    end

    test "is unknown outside a git repo", %{dir: dir} do
      assert Version.dev_branch(dir) == "unknown"
    end

    # A child's stderr bypasses ExUnit, so a separate BEAM, its stderr
    # folded into the output, asks.
    test "prints nothing outside a git repo", %{dir: dir} do
      ebin = Application.app_dir(:meerkat, "ebin")

      {out, 0} =
        System.cmd(
          "elixir",
          ["-pa", ebin, "-e", "IO.write(Meerkat.Version.dev_branch(hd(System.argv())))", dir],
          stderr_to_stdout: true
        )

      assert out == "unknown"
    end

    test "is unknown when git cannot be run", %{dir: dir} do
      Meerkat.TestHelpers.put_env("PATH", dir)
      assert Version.dev_branch(dir) == "unknown"
    end
  end

  test "warns and falls back to dev when a release manifest is unreadable" do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-rr")
    File.mkdir_p!(dir)
    System.put_env("RELEASE_ROOT", dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    log = capture_log(fn -> assert Version.info().dev? end)
    assert log =~ ~r/Meerkat.Version: unreadable version manifest \(\{:error, :enoent\}\)\n/
  end

  test "a manifest written with CRLF line endings or trailing spaces still parses" do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-crlf")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "meerkat_version"),
      "2b4dd74ce4c3abc\r\nhttps://github.com/miridius/meerkat \r\nSome change (#5)\r\n"
    )

    System.put_env("RELEASE_ROOT", dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    info = Version.info()

    assert info.label == "2b4dd74"

    assert info.changelog == [
             %{number: 5, title: "Some change", url: "https://github.com/miridius/meerkat/pull/5"}
           ]
  end
end
