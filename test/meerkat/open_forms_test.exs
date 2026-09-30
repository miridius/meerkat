defmodule Meerkat.OpenFormsTest do
  use ExUnit.Case, async: true

  alias Meerkat.OpenForms

  @inline %{surface: :inline, anchor: %{file_index: 0, start_line: 4, end_line: 6, side: "new"}}
  @global %{surface: :global, anchor: %{}}

  describe "key/1" do
    test "names each surface by its anchor" do
      assert OpenForms.key(@inline) == "inline:0:new:4-6"
      assert OpenForms.key(@global) == "global"
      assert OpenForms.key(%{surface: :file, anchor: %{file_index: 2}}) == "file:2"

      assert OpenForms.key(%{surface: :commit_msg, anchor: %{start_line: 1, end_line: 3}}) ==
               "commit_msg:1-3"
    end

    test "an edit form's key names the comment it edits" do
      assert OpenForms.key(Map.put(@global, :edit_id, "c9")) == "global:edit:c9"
      assert OpenForms.key(Map.put(@global, :edit_id, nil)) == "global"
    end
  end

  describe "open/2" do
    test "appends a form with a new key" do
      assert OpenForms.open([@inline], @global) == [@inline, @global]
    end

    test "keeps the form already open under the same key" do
      again = Map.put(@inline, :initial_body, "other")
      assert OpenForms.open([@inline], again) == [@inline]
    end
  end

  test "close/2 drops only the form with that key" do
    assert OpenForms.close([@inline, @global], "global") == [@inline]
    assert OpenForms.close([@inline], "missing") == [@inline]
  end

  test "find/2 returns the form with that key, or nil" do
    assert OpenForms.find([@inline, @global], "inline:0:new:4-6") == @inline
    assert OpenForms.find([@inline], "global") == nil
    assert OpenForms.find([@inline], nil) == nil
  end
end
