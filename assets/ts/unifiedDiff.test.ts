import { expect, test } from "bun:test";
import { unifiedDiff } from "./unifiedDiff";

// `@git-diff-view` reads an empty line as a context line, so a blank
// line between hunks showed as an extra row after each hunk.
test("hunks follow each other with no blank line between them", () => {
	const hunks = ["@@ -2,3 +2,3 @@\n bravo\n charlie\n delta\n", "@@ -5,0 +5,1 @@\n+echo\n"];
	expect(unifiedDiff("a.txt", "b.txt", hunks)).toBe(
		"diff --git a/a.txt b/b.txt\n--- a/a.txt\n+++ b/b.txt\n" +
			"@@ -2,3 +2,3 @@\n bravo\n charlie\n delta\n" +
			"@@ -5,0 +5,1 @@\n+echo\n",
	);
});
