defmodule Meerkat.TmpPathTest do
  use ExUnit.Case, async: true

  alias Meerkat.TmpPath

  test "names a path in the tmp dir by prefix, OS pid and a unique integer" do
    path = TmpPath.unique("meerkat-x")

    assert path == Path.join(System.tmp_dir!(), Path.basename(path))
    assert Path.basename(path) =~ ~r/\Ameerkat-x-#{System.pid()}-\d+\z/
  end

  test "names a different path on each call" do
    refute TmpPath.unique("meerkat-x") == TmpPath.unique("meerkat-x")
  end
end
