// Compiles once with MIX_ENV=test, then runs each test/**/*_test.exs file as its own `mix test --no-compile` BEAM
// through scripts/run-test-file.sh, with parallelism capped at half the online cores (minimum one).
//
// Many modules are `async: false` because they change process-wide state: environment variables, application env,
// or singleton processes. One `mix test` runs them serially; separate BEAMs share none of that state, so those files
// can run together. Half the cores took as long as all of them and loads the machine less.
//
// Each file also takes one of as many test-file slots, which all runs of this script in all worktrees share, so two
// at once run no more files together than one. Test files contend for more than the CPU: with 9 at once on 18 cores,
// the CPU stayed half idle, yet the files took 1.7 times as long in all as with 2.
//
// On failure, prints each failing file's output, lists the failing files, and exits non-zero. CI and the pre-commit
// gate both run this script, so each runs the files the same way.
//
// Once every file has passed, runs each file that took longer than the limit in scripts/test-file-limit.json, without
// an entry there giving a reason, again, one at a time, and fails when that run is also over the limit or fails. This
// run's other files slow a file down, most in wall time, so only the second run judges its speed; other runs' files
// may still run beside it.
//
// Locally a file's time is its CPU time, user and system, which outside load barely moves, judged against
// cpu_limit_seconds; in CI (CI=true) it is its wall time, which also counts waiting, judged against limit_seconds.
//
// Usage: bun scripts/mix-test.ts
import { closeSync, mkdtempSync, openSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export const LIMITS = "scripts/test-file-limit.json";

// One run of a test file: its exit status, or null when it did not finish, its output, and, when it passed, the wall,
// user and system seconds run-test-file.sh wrote for it.
export type Run = { status: number | null; output: string; times: string };

// What the run does outside this file, so tests can stand in for it.
export type Io = {
	compile(): number;
	cores(): number;
	testFiles(): { file: string; lines: number }[];
	run(slots: number, file: string): Promise<Run>;
	readLimits(): string;
	print(text: string): void;
	error(text: string): void;
};

// A problem with the limits or the times, which fails the run.
export class Failure extends Error {}

// Largest first, so the longest runs start early rather than pile up at the end.
export function byLines(files: { file: string; lines: number }[]): string[] {
	return files.toSorted((a, b) => b.lines - a.lines || a.file.localeCompare(b.file)).map(({ file }) => file);
}

export const jobCount = (cores: number) => Math.max(1, Math.floor(cores / 2));

// Runs `run` on each item, at most `jobs` at once, and returns the results in the items' order.
export async function pool<T>(items: string[], jobs: number, run: (item: string) => Promise<T>): Promise<T[]> {
	const results: T[] = new Array(items.length);
	let next = 0;
	const worker = async () => {
		while (next < items.length) {
			const index = next++;
			results[index] = await run(items[index]);
		}
	};
	await Promise.all(Array.from({ length: Math.min(jobs, items.length) }, worker));
	return results;
}

// Each failing file's output, then the list of them.
export function failureReport(files: string[], runs: Run[]): string {
	const failed = files.filter((_, i) => runs[i].status !== 0);
	const outputs = files.map((file, i) => {
		const { status, output } = runs[i];
		if (status === null) return `\n=== mix test ${file} did not finish ===\n`;
		return status === 0 ? "" : `\n=== mix test ${file} ===\n${output}`;
	});
	const list = failed.map((file) => `  ${file}\n`).join("");
	return `${outputs.join("")}\nmix test: ${failed.length} of ${files.length} test files failed:\n${list}`;
}

export function parseLimits(read: () => string, wall: boolean): { limitSeconds: number; exempt: Set<string> } {
	let parsed: unknown;
	try {
		parsed = JSON.parse(read());
	} catch (error) {
		throw new Failure(`cannot read ${LIMITS}: ${(error as Error).message}`);
	}
	const { exempt, ...limits } = (parsed ?? {}) as Record<string, unknown>;
	for (const key of ["limit_seconds", "cpu_limit_seconds"]) {
		const limit = limits[key];
		if (typeof limit !== "number" || !(limit > 0)) throw new Failure(`${LIMITS} needs a positive ${key}.`);
	}
	if (typeof exempt !== "object" || exempt === null || Array.isArray(exempt)) {
		throw new Failure(`${LIMITS} needs an exempt object.`);
	}
	for (const [file, entry] of Object.entries(exempt)) {
		const reason = (entry as Record<string, unknown> | null)?.reason;
		if (typeof reason !== "string" || reason.trim() === "") {
			throw new Failure(`${LIMITS} entry ${file} needs a non-empty reason.`);
		}
	}
	const limitSeconds = limits[wall ? "limit_seconds" : "cpu_limit_seconds"] as number;
	return { limitSeconds, exempt: new Set(Object.keys(exempt)) };
}

// A run's time in whole milliseconds, which add up exactly: its wall time, or in CPU mode its user and system time.
// Bash's `time` writes the locale's decimal separator.
export function parseMs(times: string, wall: boolean, what: string): number {
	const text = times.trim();
	const ms = text.split(" ").map((field) => Math.round(Number(field.replace(",", ".")) * 1000));
	if (ms.length !== 3 || !ms.every(Number.isFinite)) throw new Failure(`cannot read the times of ${what}: "${text}"`);
	const [real, user, sys] = ms;
	return wall ? real : user + sys;
}

// Seconds rounded up to a tenth, so a time over the limit never shows as the limit.
export const show = (ms: number) => (Math.ceil(ms / 100) / 10).toFixed(1);

// Runs each file over the limit again, one at a time, and returns whether every one of them passed within it.
async function judgeTimes(io: Io, wall: boolean, slots: number, files: string[], runs: Run[]): Promise<boolean> {
	const { limitSeconds, exempt } = parseLimits(io.readLimits, wall);
	const measure = wall ? "wall-time" : "CPU-time";
	const isOver = (ms: number) => ms > limitSeconds * 1000;

	const slow = files.flatMap((file, i) => {
		if (exempt.has(file)) return [];
		const ms = parseMs(runs[i].times, wall, file);
		return isOver(ms) ? [{ file, ms }] : [];
	});
	if (slow.length === 0) return true;

	io.print(
		`\nmix test: running again, after this run's other files, each test file over the ${limitSeconds} s ${measure} limit beside them:\n`,
	);
	const over: { file: string; ms: number }[] = [];
	let failed = false;
	for (const { file, ms: beside } of slow) {
		const again = await io.run(slots, file);
		if (again.status !== 0) {
			failed = true;
			io.print(`  ${file}: ${show(beside)} s beside others; failed when run again\n`);
			io.print(`\n=== mix test ${file}, run again ===\n${again.output}\n`);
			continue;
		}
		const ms = parseMs(again.times, wall, `${file} run again`);
		io.print(`  ${file}: ${show(beside)} s beside others, ${show(ms)} s run again\n`);
		if (isOver(ms)) over.push({ file, ms });
	}

	if (over.length > 0) {
		io.print(`\nmix test: test files over the ${limitSeconds} s ${measure} limit for one file, run again:\n`);
		for (const { file, ms } of over) io.print(`  ${file}: ${show(ms)} s\n`);
		io.print(`Make each faster or split it. List one in ${LIMITS} only with a reason it must stay slow.\n`);
	}
	if (failed) io.print("\nmix test: a test file run again failed.\n");
	return !failed && over.length === 0;
}

// Returns the run's exit status.
export async function runSuite(io: Io, wall: boolean): Promise<number> {
	const compiled = io.compile();
	if (compiled !== 0) return compiled;

	const files = byLines(io.testFiles());
	if (files.length === 0) {
		io.error("mix test: no *_test.exs files under test/.\n");
		return 1;
	}

	const jobs = jobCount(io.cores());
	const runs = await pool(files, jobs, (file) => io.run(jobs, file));
	if (runs.some(({ status }) => status !== 0)) {
		io.print(failureReport(files, runs));
		return 1;
	}

	try {
		if (!(await judgeTimes(io, wall, jobs, files, runs))) return 1;
	} catch (error) {
		if (!(error instanceof Failure)) throw error;
		io.error(`mix test: ${error.message}\n`);
		return 1;
	}
	io.print(`mix test: all ${files.length} test files passed.\n`);
	return 0;
}

// Runs each file through run-test-file.sh, keeping its output and times in `logs`.
function realIo(logs: string): Io {
	const env = { ...process.env, MIX_ENV: "test" };
	let runs = 0;
	return {
		compile: () => Bun.spawnSync(["mix", "compile"], { env, stdio: ["inherit", "inherit", "inherit"] }).exitCode ?? 1,
		cores() {
			const cores = Number(Bun.spawnSync(["getconf", "_NPROCESSORS_ONLN"]).stdout.toString());
			if (!Number.isInteger(cores) || cores < 1) throw new Error("getconf reports no online cores.");
			return cores;
		},
		testFiles: () =>
			Array.from(new Bun.Glob("test/**/*_test.exs").scanSync({ dot: true }), (file) => ({
				file,
				lines: readFileSync(file, "utf8").split("\n").length - 1,
			})),
		async run(slots, file) {
			const log = join(logs, String(runs++));
			const out = openSync(log, "w");
			const proc = Bun.spawn(["bash", "scripts/run-test-file.sh", String(slots), file, `${log}.secs`], {
				env,
				stdio: ["ignore", out, out],
			});
			closeSync(out);
			await proc.exited;
			const status = proc.signalCode === null ? proc.exitCode : null;
			const times = status === 0 ? readFileSync(`${log}.secs`, "utf8") : "";
			return { status, output: readFileSync(log, "utf8"), times };
		},
		readLimits: () => readFileSync(LIMITS, "utf8"),
		print: (text) => process.stdout.write(text),
		error: (text) => process.stderr.write(text),
	};
}

if (import.meta.main) {
	process.chdir(join(import.meta.dir, ".."));
	const logs = mkdtempSync(join(tmpdir(), "mix-test-"));
	process.on("exit", () => rmSync(logs, { recursive: true, force: true }));
	process.on("SIGINT", () => process.exit(130));
	process.on("SIGTERM", () => process.exit(143));
	process.exitCode = await runSuite(realIo(logs), process.env.CI === "true");
}
