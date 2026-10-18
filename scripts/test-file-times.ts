// Run by scripts/mix-test.sh after its test files: prints the 10 slowest, and
// fails when one took longer than the limit in scripts/test-file-limit.json
// without an entry there giving a reason.
//
// Usage: bun scripts/test-file-times.ts <logs dir> <test file>...
// Each finished file's wall time, in whole seconds, is in <logs dir>/<file>.secs.
import { existsSync, readFileSync } from "node:fs";

const LIMITS = "scripts/test-file-limit.json";

type Limits = { limitSeconds: number; exempt: Map<string, string> };

function fail(message: string): never {
	console.error(`mix test: ${message}`);
	process.exit(1);
}

function loadLimits(): Limits {
	let parsed: unknown;
	try {
		parsed = JSON.parse(readFileSync(LIMITS, "utf8"));
	} catch (error) {
		fail(`cannot read ${LIMITS}: ${(error as Error).message}`);
	}
	const { limit_seconds, exempt } = (parsed ?? {}) as Record<string, unknown>;
	if (typeof limit_seconds !== "number" || !(limit_seconds > 0)) {
		fail(`${LIMITS} needs a positive limit_seconds.`);
	}
	if (typeof exempt !== "object" || exempt === null || Array.isArray(exempt)) {
		fail(`${LIMITS} needs an exempt object.`);
	}
	const reasons = new Map<string, string>();
	for (const [file, entry] of Object.entries(exempt)) {
		const reason = (entry as Record<string, unknown> | null)?.reason;
		if (typeof reason !== "string" || reason.trim() === "") {
			fail(`${LIMITS} entry ${file} needs a non-empty reason.`);
		}
		reasons.set(file, reason);
	}
	return { limitSeconds: limit_seconds, exempt: reasons };
}

const [logs, ...files] = process.argv.slice(2);
const { limitSeconds, exempt } = loadLimits();

const times = files
	.filter((file) => existsSync(`${logs}/${file}.secs`))
	.map((file) => ({ file, secs: Number(readFileSync(`${logs}/${file}.secs`, "utf8")) }))
	.sort((a, b) => b.secs - a.secs);

console.log("\nmix test: slowest test files:");
for (const { file, secs } of times.slice(0, 10)) {
	console.log(`  ${String(secs).padStart(4)} s  ${file}${exempt.has(file) ? "  (exempt)" : ""}`);
}

const over = times.filter(({ file, secs }) => secs > limitSeconds && !exempt.has(file));
if (over.length > 0) {
	console.log(`\nmix test: test files over the ${limitSeconds} s limit for one file:`);
	for (const { file, secs } of over) console.log(`  ${file}: ${secs} s`);
	console.log(
		`Make each faster or split it. List one in ${LIMITS} only with a reason it must stay slow.`,
	);
	process.exit(1);
}
