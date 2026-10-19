// Run by scripts/mix-test.sh after its test files: runs each passing file that took longer than the limit in
// scripts/test-file-limit.json, without an entry there giving a reason, again on its own, and fails when that run
// is also over the limit or fails. Other test files slow a file down, so only the second run judges its own speed.
//
// Usage: bun scripts/test-file-times.ts <logs dir> <test-file slots> <test file>...
// Each finished file's wall time, in whole seconds, is in <logs dir>/<file>.secs, and its exit status in
// <logs dir>/<file>.status.
import { existsSync, openSync, readFileSync } from "node:fs";

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

const [logs, slots, ...files] = process.argv.slice(2);
const { limitSeconds, exempt } = loadLimits();

const passed = (file: string) =>
	existsSync(`${logs}/${file}.status`) && readFileSync(`${logs}/${file}.status`, "utf8").trim() === "0";
const secs = (path: string) => Number(readFileSync(path, "utf8"));

const slow = files
	.filter((file) => passed(file) && !exempt.has(file))
	.map((file) => ({ file, secs: secs(`${logs}/${file}.secs`) }))
	.filter(({ secs }) => secs > limitSeconds);
if (slow.length === 0) process.exit(0);

console.log(`\nmix test: running again on its own each test file over the ${limitSeconds} s limit beside others:`);
const over: { file: string; secs: number }[] = [];
let failed = false;
for (const { file, secs: beside } of slow) {
	const log = `${logs}/${file}.alone`;
	const out = openSync(log, "w");
	const run = Bun.spawnSync(["bash", "scripts/run-test-file.sh", slots, file, `${log}.secs`], {
		stdio: ["ignore", out, out],
	});
	if (run.exitCode !== 0) {
		failed = true;
		console.log(`  ${file}: ${beside} s beside others; failed on its own`);
		console.log(`\n=== mix test ${file}, run again on its own ===`);
		console.log(readFileSync(log, "utf8"));
		continue;
	}
	const alone = secs(`${log}.secs`);
	console.log(`  ${file}: ${beside} s beside others, ${alone} s alone`);
	if (alone > limitSeconds) over.push({ file, secs: alone });
}

if (over.length > 0) {
	console.log(`\nmix test: test files over the ${limitSeconds} s limit for one file, run on their own:`);
	for (const { file, secs } of over) console.log(`  ${file}: ${secs} s`);
	console.log(
		`Make each faster or split it. List one in ${LIMITS} only with a reason it must stay slow.`,
	);
}
if (failed) console.log("\nmix test: a test file run again on its own failed.");
if (failed || over.length > 0) process.exit(1);
