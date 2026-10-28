// Run by scripts/mix-test.sh once all its test files have passed: runs each file that took longer than the limit
// in scripts/test-file-limit.json, without an entry there giving a reason, again, one at a time, and fails when
// that run is also over the limit or fails. This run's other files slow a file down, most in wall time, so only the
// second run judges its speed; other runs' files may still run beside it.
//
// Locally a file's time is its CPU time, user and system, which outside load barely moves, judged against
// cpu_limit_seconds; in CI (CI=true) it is its wall time, which also counts waiting, judged against limit_seconds.
//
// Usage: bun scripts/test-file-times.ts <logs dir> <test-file slots> <test file>...
// Each file's wall, user and system seconds are in <logs dir>/<file>.secs.
import { closeSync, openSync, readFileSync } from "node:fs";

const LIMITS = "scripts/test-file-limit.json";

type Limits = { limitSeconds: number; exempt: Map<string, string> };

function fail(message: string): never {
	console.error(`mix test: ${message}`);
	process.exit(1);
}

const wall = process.env.CI === "true";
const measure = wall ? "wall-time" : "CPU-time";
const limitKey = wall ? "limit_seconds" : "cpu_limit_seconds";

function loadLimits(): Limits {
	let parsed: unknown;
	try {
		parsed = JSON.parse(readFileSync(LIMITS, "utf8"));
	} catch (error) {
		fail(`cannot read ${LIMITS}: ${(error as Error).message}`);
	}
	const { exempt, ...limits } = (parsed ?? {}) as Record<string, unknown>;
	for (const key of ["limit_seconds", "cpu_limit_seconds"]) {
		const limit = limits[key];
		if (typeof limit !== "number" || !(limit > 0)) fail(`${LIMITS} needs a positive ${key}.`);
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
	return { limitSeconds: limits[limitKey] as number, exempt: reasons };
}

const [logs, slots, ...files] = process.argv.slice(2);
const { limitSeconds, exempt } = loadLimits();

// The file's time in whole milliseconds, which add up exactly. Bash's `time` writes the locale's decimal separator.
function readMs(path: string): number {
	const text = readFileSync(path, "utf8").trim();
	const ms = text.split(" ").map((field) => Math.round(Number(field.replace(",", ".")) * 1000));
	if (ms.length !== 3 || !ms.every(Number.isFinite)) fail(`cannot read the times in ${path}: "${text}"`);
	const [real, user, sys] = ms;
	return wall ? real : user + sys;
}

const isOver = (ms: number) => ms > limitSeconds * 1000;
// Seconds rounded up to a tenth, so a time over the limit never shows as the limit.
const show = (ms: number) => (Math.ceil(ms / 100) / 10).toFixed(1);

const slow = files
	.filter((file) => !exempt.has(file))
	.map((file) => ({ file, ms: readMs(`${logs}/${file}.secs`) }))
	.filter(({ ms }) => isOver(ms));
if (slow.length === 0) process.exit(0);

console.log(
	`\nmix test: running again, after this run's other files, each test file over the ${limitSeconds} s ${measure} limit beside them:`,
);
const over: { file: string; ms: number }[] = [];
let failed = false;
for (const { file, ms: beside } of slow) {
	const log = `${logs}/${file}.again`;
	const out = openSync(log, "w");
	const run = Bun.spawnSync(["bash", "scripts/run-test-file.sh", slots, file, `${log}.secs`], {
		stdio: ["ignore", out, out],
	});
	closeSync(out);
	if (run.exitCode !== 0) {
		failed = true;
		console.log(`  ${file}: ${show(beside)} s beside others; failed when run again`);
		console.log(`\n=== mix test ${file}, run again ===`);
		console.log(readFileSync(log, "utf8"));
		continue;
	}
	const again = readMs(`${log}.secs`);
	console.log(`  ${file}: ${show(beside)} s beside others, ${show(again)} s run again`);
	if (isOver(again)) over.push({ file, ms: again });
}

if (over.length > 0) {
	console.log(`\nmix test: test files over the ${limitSeconds} s ${measure} limit for one file, run again:`);
	for (const { file, ms } of over) console.log(`  ${file}: ${show(ms)} s`);
	console.log(
		`Make each faster or split it. List one in ${LIMITS} only with a reason it must stay slow.`,
	);
}
if (failed) console.log("\nmix test: a test file run again failed.");
if (failed || over.length > 0) process.exit(1);
