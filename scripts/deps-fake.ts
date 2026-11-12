// A stand-in Sys for the tests of scripts/outdated.ts, scripts/bump-deps.ts
// and scripts/rebase-bump.ts. Each command gets the reply the last matching `on`
// gave, or exit 0 with no output; the file map stands in for the tree.

import type { Ran, RunOptions, Sys } from "./deps-common.ts";

export type Call = { cmd: string } & RunOptions;
type Reply = Partial<Ran> | ((call: Call) => Partial<Ran>);

export const HEX_HEADER = "Dependency  Only  Current  Latest  Status\n";
export const OLD = "2020-01-01T00:00:00.000000Z";
export const NOW = Date.parse("2026-06-01T12:00:00Z");
// Twelve hours before NOW.
export const YOUNG = "2026-06-01T00:00:00Z";

// hex.pm's package record listing RELEASES, [version, inserted_at] pairs,
// newest version first as hex.pm does.
export function releases(list: [string, string][], fields: Record<string, unknown> = {}): string {
	return JSON.stringify({ ...fields, releases: list.map(([version, inserted_at]) => ({ version, inserted_at })) });
}

export function entry(version: string, reason = "upstream needs shiki 3") {
	return { version, reason };
}

export class Fake {
	readonly lines: string[] = [];
	readonly calls: Call[] = [];
	readonly removed: string[] = [];
	readonly env: Record<string, string | undefined> = {};
	tools = new Set(["mix", "elixir", "pnpm", "curl"]);
	scratch: string | null = "/scratch";
	private replies: [string | RegExp, Reply][] = [];

	constructor(public files: Record<string, string> = {}) {
		this.on("git rev-parse --local-env-vars", { stdout: "GIT_DIR\nGIT_INDEX_FILE\n" });
		this.hexReport(`${HEX_HEADER}mdex  0.14.1  0.14.1  Up-to-date\n`);
		this.pnpmReport("{}");
		this.exempt({});
	}

	// on MATCH REPLY: answers each command equal to, or matching, MATCH.
	on(match: string | RegExp, reply: Reply): this {
		this.replies.unshift([match, reply]);
		return this;
	}

	hexReport(report: string, code = 1) {
		return this.on("mix hex.outdated", { stdout: report, code });
	}

	// pnpmReport REPORT REGISTRY: pnpm outdated's report with the floor, and
	// without it, REGISTRY or else REPORT.
	pnpmReport(report: string, registry?: string) {
		this.on(/^pnpm -r outdated --format json/, { stdout: report, code: 1 });
		if (registry !== undefined)
			this.on("pnpm -r outdated --format json --config.minimum-release-age=0", { stdout: registry, code: 1 });
		return this;
	}

	hexApi(name: string, body: string, code = 0) {
		return this.on(`curl -sSf --max-time 10 https://hex.pm/api/packages/${name}`, { stdout: body, code });
	}

	exempt(table: Record<string, unknown> | string) {
		this.files["scripts/dep-exemptions.json"] = typeof table === "string" ? table : JSON.stringify(table);
		return this;
	}

	get text() {
		return this.lines.join("\n");
	}

	get ran() {
		return this.calls.map((c) => c.cmd);
	}

	readonly sys: Sys = {
		prefix: "test:",
		env: this.env,
		run: async (cmd, options = {}) => {
			const call = { cmd: cmd.join(" "), ...options };
			this.calls.push(call);
			const found = this.replies.find(([m]) => (typeof m === "string" ? m === call.cmd : m.test(call.cmd)));
			const reply = found ? (typeof found[1] === "function" ? found[1](call) : found[1]) : {};
			const ran = { code: 0, stdout: "", stderr: "", ...reply };
			if (options.inherit) {
				for (const text of [ran.stdout, ran.stderr]) if (text) this.lines.push(text.replace(/\n$/, ""));
				return { ...ran, stdout: "", stderr: "" };
			}
			return ran;
		},
		out: (text) => this.lines.push(text),
		err: (text) => this.lines.push(text),
		read: (path) => this.files[path] ?? null,
		write: (path, text) => {
			this.files[path] = text;
		},
		which: (tool) => this.tools.has(tool),
		now: () => NOW,
		scratchWorkspace: () => this.scratch,
		remove: (path) => {
			this.removed.push(path);
		},
	};
}
