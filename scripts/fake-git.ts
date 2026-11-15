// A stand-in git for the scripts' unit tests. It answers each command,
// keyed by its arguments joined with spaces, from `answers`, a string for
// output with status 0; any other command fails with status 128. `ran`
// logs each command with its options.
import type { Git, GitResult } from "./checked-trees";

export function fakeGit(answers: Record<string, GitResult | string>) {
	const ran: { args: string; input?: string; env?: unknown }[] = [];
	const g: Git = (args, opts = {}) => {
		ran.push({ args: args.join(" "), ...opts });
		const a = answers[args.join(" ")];
		if (a === undefined) return { status: 128, out: "" };
		return typeof a === "string" ? { status: 0, out: a } : a;
	};
	return { g, ran };
}
