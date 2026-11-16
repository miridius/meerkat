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
    assert String.starts_with?(info.label, "dev: ")
  end

  test "warns and falls back to dev when a release manifest is unreadable" do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-rr")
    File.mkdir_p!(dir)
    System.put_env("RELEASE_ROOT", dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    log = capture_log(fn -> assert Version.info().dev? end)
    assert log =~ "Meerkat.Version: unreadable version manifest ({:error, :enoent})"
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
