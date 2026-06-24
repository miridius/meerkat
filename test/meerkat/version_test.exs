defmodule Meerkat.VersionTest do
  # async: false: RELEASE_ROOT is process-global env.
  use ExUnit.Case, async: false

  alias Meerkat.Version

  setup do
    prev = System.get_env("RELEASE_ROOT")

    on_exit(fn ->
      if prev, do: System.put_env("RELEASE_ROOT", prev), else: System.delete_env("RELEASE_ROOT")
    end)

    :ok
  end

  defp with_manifest(lines) do
    dir = Path.join(System.tmp_dir!(), "meerkat-ver-#{System.unique_integer([:positive])}")
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

  test "falls back to dev info without a release root" do
    System.delete_env("RELEASE_ROOT")

    info = Version.info()

    assert info.dev?
    assert info.changelog == []
    assert String.starts_with?(info.label, "dev: ")
  end
end
