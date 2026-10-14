defmodule Meerkat.IntralineTest do
  use ExUnit.Case, async: true

  alias Meerkat.Intraline

  test "matched run passes through" do
    hunk = "@@ -1,3 +1,3 @@\n ctx\n-old2\n-old3\n+new2\n+new3\n"
    assert Intraline.split([hunk]) == [hunk]
  end

  test "mismatched run splits paired from orphan" do
    hunk = "@@ -1,4 +1,3 @@\n ctx\n-a\n-b\n-c\n+x\n+y\n"

    assert Intraline.split([hunk]) == [
             "@@ -1,3 +1,3 @@\n ctx\n-a\n-b\n+x\n+y\n",
             "@@ -4,1 +4,0 @@\n-c\n"
           ]
  end

  test "mismatched run at start of hunk" do
    hunk = "@@ -1,5 +1,4 @@\n-a\n-b\n-c\n-d\n-e\n+w\n+x\n+y\n+z\n"

    assert Intraline.split([hunk]) == [
             "@@ -1,4 +1,4 @@\n-a\n-b\n-c\n-d\n+w\n+x\n+y\n+z\n",
             "@@ -5,1 +5,0 @@\n-e\n"
           ]
  end

  test "additions exceed deletions" do
    hunk = "@@ -1,2 +1,5 @@\n-a\n-b\n+x\n+y\n+z1\n+z2\n+z3\n"

    assert Intraline.split([hunk]) == [
             "@@ -1,2 +1,2 @@\n-a\n-b\n+x\n+y\n",
             "@@ -3,0 +3,3 @@\n+z1\n+z2\n+z3\n"
           ]
  end

  # With nothing to pair, a split would only cut the hunk in two and
  # show a header that disagrees with git's.
  test "one-sided runs pass through unsplit" do
    added = "@@ -2,3 +2,4 @@\n bravo\n charlie\n delta\n+echo\n"
    removed = "@@ -1,3 +1,2 @@\n a\n-b\n c\n"
    assert Intraline.split([added, removed]) == [added, removed]
  end

  test "lines after a split start a hunk where the run ended" do
    hunk = "@@ -1,6 +1,4 @@\n-a\n-b\n+x\n ctx\n-c\n-d\n+y\n"

    assert Intraline.split([hunk]) == [
             "@@ -1,1 +1,1 @@\n-a\n+x\n",
             "@@ -2,1 +2,0 @@\n-b\n",
             "@@ -3,2 +2,2 @@\n ctx\n-c\n+y\n",
             "@@ -5,1 +4,0 @@\n-d\n"
           ]
  end

  test "a one-sided run before a split stays with the paired lines" do
    hunk = "@@ -1,3 +1,4 @@\n+n\n a\n-b\n-c\n+x\n"

    assert Intraline.split([hunk]) == [
             "@@ -1,2 +1,3 @@\n+n\n a\n-b\n+x\n",
             "@@ -3,1 +4,0 @@\n-c\n"
           ]
  end

  test "a no-newline marker after a split travels with the orphan" do
    hunk = "@@ -1,1 +1,2 @@\n-a\n+x\n+y\n\\ No newline at end of file\n ctx\n"

    assert Intraline.split([hunk]) == [
             "@@ -1,1 +1,1 @@\n-a\n+x\n",
             "@@ -2,0 +2,1 @@\n+y\n\\ No newline at end of file\n",
             "@@ -2,1 +3,1 @@\n ctx\n"
           ]
  end

  test "a no-newline marker after a split stays with the paired addition it describes" do
    hunk = "@@ -1,2 +1,1 @@\n-a\n-b\n+x\n\\ No newline at end of file\n"

    assert Intraline.split([hunk]) == [
             "@@ -1,1 +1,1 @@\n-a\n+x\n\\ No newline at end of file\n",
             "@@ -2,1 +2,0 @@\n-b\n"
           ]
  end

  test "a hunk with no trailing newline gains one" do
    assert Intraline.split(["@@ -1,1 +1,1 @@\n-a\n+b"]) == ["@@ -1,1 +1,1 @@\n-a\n+b\n"]
  end

  test "an empty line inside a hunk is kept" do
    hunk = "@@ -1,3 +1,3 @@\n a\n\n-b\n+c\n"
    assert Intraline.split([hunk]) == ["@@ -1,2 +1,2 @@\n a\n\n-b\n+c\n"]
  end

  test "malformed hunk passed through unchanged" do
    hunk = "not-a-hunk\nrandom\n"
    assert Intraline.split([hunk]) == [hunk]
  end

  test "a header with no body passes through unchanged" do
    for hunk <- ["@@ -1,0 +1,0 @@", "@@ -1,0 +1,0 @@\n"] do
      assert Intraline.split([hunk]) == [hunk]
    end
  end

  test "pure addition with a no-newline marker stays one hunk" do
    hunk = "@@ -0,0 +1,2 @@\n+line1\n+line2\n\\ No newline at end of file\n"
    assert Intraline.split([hunk]) == [hunk]
  end
end
