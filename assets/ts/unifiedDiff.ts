/** The one unified-diff string `@git-diff-view` parses for a file: a
 *  `diff --git` header, then the file's hunks. Each hunk the server
 *  sends ends in a newline, so they join with no separator. */
export function unifiedDiff(oldName: string, newName: string, hunks: string[]): string {
	return `diff --git a/${oldName} b/${newName}\n--- a/${oldName}\n+++ b/${newName}\n${hunks.join("")}`;
}
