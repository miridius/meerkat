defmodule Meerkat.IntralineTest do
  use ExUnit.Case, async: true

  alias Meerkat.Intraline

  test "matched run passes through" do
    hunk = "@@ -1,3 +1,3 @@\n ctx\n-old2\n-old3\n+new2\n+new3\n"
    [out] = Intraline.split([hunk])
    assert out =~ "ctx"
    assert out =~ "-old2"
    assert out =~ "-old3"
    assert out =~ "+new2"
    assert out =~ "+new3"
  end

  test "mismatched run splits paired from orphan" do
    # 1 ctx + run(3 del, 2 add). Expected:
    #   sub 1: ctx + 2 del + 2 add  (pair_count=2)
    #   sub 2: 1 del  (orphan, header -4,1 +4,0)
    hunk = "@@ -1,4 +1,3 @@\n ctx\n-a\n-b\n-c\n+x\n+y\n"
    out = Intraline.split([hunk])
    assert length(out) == 2
    [first, orphan] = out
    assert String.starts_with?(first, "@@ -1,3 +1,3 @@\n")

    for tok <- ["ctx", "-a", "-b", "+x", "+y"] do
      assert first =~ tok, "first sub-hunk missing #{tok}: #{first}"
    end

    refute first =~ "-c"
    assert String.starts_with?(orphan, "@@ -4,1 +4,0 @@\n")
    assert orphan =~ "-c"
  end

  test "mismatched run at start of hunk" do
    hunk = "@@ -1,5 +1,4 @@\n-a\n-b\n-c\n-d\n-e\n+w\n+x\n+y\n+z\n"
    out = Intraline.split([hunk])
    assert length(out) == 2
    [first, orphan] = out
    assert String.starts_with?(first, "@@ -1,4 +1,4 @@\n")

    for tok <- ["-a", "-b", "-c", "-d", "+w", "+x", "+y", "+z"] do
      assert first =~ tok, "missing #{tok} in #{first}"
    end

    refute first =~ "-e"
    assert String.starts_with?(orphan, "@@ -5,1 +5,0 @@\n")
    assert orphan =~ "-e"
  end

  test "additions exceed deletions" do
    hunk = "@@ -1,2 +1,5 @@\n-a\n-b\n+x\n+y\n+z1\n+z2\n+z3\n"
    out = Intraline.split([hunk])
    assert length(out) == 2
    [first, orphan] = out
    assert String.starts_with?(first, "@@ -1,2 +1,2 @@\n")
    assert String.starts_with?(orphan, "@@ -3,0 +3,3 @@\n")
    for tok <- ["+z1", "+z2", "+z3"], do: assert(orphan =~ tok)
  end

  test "multiple mismatched runs in one hunk" do
    hunk = "@@ -1,6 +1,4 @@\n-a\n-b\n+x\n ctx\n-c\n-d\n+y\n"
    out = Intraline.split([hunk])
    assert length(out) >= 3
    joined = Enum.join(out, "\n---\n")
    for tok <- ["-a", "-b", "+x", "ctx", "-c", "-d", "+y"], do: assert(joined =~ tok)
  end

  test "malformed hunk passed through unchanged" do
    hunk = "not-a-hunk\nrandom\n"
    assert Intraline.split([hunk]) == [hunk]
  end

  test "pure addition with no newline trailer absorbs into orphan" do
    hunk = "@@ -0,0 +1,2 @@\n+line1\n+line2\n\\ No newline at end of file\n"
    out = Intraline.split([hunk])
    # 0 dels + 2 adds — orphan-only; trailer travels with the orphan.
    assert length(out) == 1
    joined = List.first(out)
    assert joined =~ "+line1"
    assert joined =~ "+line2"
    assert joined =~ "\\ No newline at end of file"
  end
end
