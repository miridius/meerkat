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
    #   sub 1: ctx + 2 del + 2 add  (pair_count=2), with git's header
    #   sub 2: 1 del  (orphan, header -4,1 +4,0)
    hunk = "@@ -1,4 +1,3 @@\n ctx\n-a\n-b\n-c\n+x\n+y\n"
    out = Intraline.split([hunk])
    assert length(out) == 2
    [first, orphan] = out
    assert String.starts_with?(first, "@@ -1,4 +1,3 @@\n")

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
    assert String.starts_with?(first, "@@ -1,5 +1,4 @@\n")

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
    assert String.starts_with?(first, "@@ -1,2 +1,5 @@\n")
    assert String.starts_with?(orphan, "@@ -3,0 +3,3 @@\n")
    for tok <- ["+z1", "+z2", "+z3"], do: assert(orphan =~ tok)
  end

  # The review page shows only the first part's header, so it carries
  # git's range for the whole hunk, without git's section heading.
  test "the first part of a split hunk keeps git's range" do
    hunk =
      "@@ -17,8 +17,7 @@ line 16\n l17\n l18\n l19\n-l20\n-l21\n+l20 and l21\n l22\n l23\n l24\n"

    assert [first, orphan, rest] = Intraline.split([hunk])
    assert first == "@@ -17,8 +17,7 @@\n l17\n l18\n l19\n-l20\n+l20 and l21\n"
    assert orphan == "@@ -21,1 +21,0 @@\n-l21\n"
    assert rest == "@@ -22,3 +21,3 @@\n l22\n l23\n l24\n"
  end

  test "a one-line range git writes without a count gets a count of one" do
    hunk = "@@ -5,2 +5 @@\n-a\n-b\n+x\n"
    assert [first, _orphan] = Intraline.split([hunk])
    assert String.starts_with?(first, "@@ -5,2 +5,1 @@\n")
  end

  # With nothing to pair, a split would only cut the hunk in two and
  # show a header that disagrees with git's.
  test "one-sided runs pass through unsplit" do
    added = "@@ -2,3 +2,4 @@\n bravo\n charlie\n delta\n+echo\n"
    removed = "@@ -1,3 +1,2 @@\n a\n-b\n c\n"
    assert Intraline.split([added, removed]) == [added, removed]
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

  test "hunk with a malformed count passed through unchanged" do
    hunk = "@@ -1,2,3 +1 @@\n-a\n-b\n+x\n"
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
