import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { type Io, jobCount, LIMITS, parseLimits, parseMs, pool, type Run, runSuite, show } from "./mix-test";

const root = join(import.meta.dir, "..");

const pass = (times = "0.1 0.1 0.1"): Run => ({ status: 0, output: "ok\n", times });
const fail = (output: string): Run => ({ status: 1, output, times: "" });

// Only test/b_test.exs is judged against limits of 1 s of CPU time and 2 s of wall time.
const overLimits = {
	limit_seconds: 2,
	cpu_limit_seconds: 1,
	exempt: { "test/a_test.exs": { reason: "only b is judged" }, "test/c_test.exs": { reason: "only b is judged" } },
};

type Fake = {
	compile?: number;
	cores?: number;
	// Each file's runs in turn; a file without one passes quickly.
	runs?: Record<string, Run[]>;
	limits?: unknown;
	readLimits?: () => string;
};

// Runs runSuite against stand-ins, returning its status, everything it printed, and each run as "<slots> <file>".
async function suite(fake: Fake = {}, wall = false) {
	const out: string[] = [];
	const calls: string[] = [];
	const io: Io = {
		compile: () => {
			calls.push("compile");
			return fake.compile ?? 0;
		},
		cores: () => fake.cores ?? 4,
		testFiles: () => [
			{ file: "test/a_test.exs", lines: 10 },
			{ file: "test/web/b_test.exs", lines: 30 },
			{ file: "test/c_test.exs", lines: 20 },
		],
		run: async (slots, file) => {
			calls.push(`${slots} ${file}`);
			return fake.runs?.[file]?.shift() ?? pass();
		},
		readLimits:
			fake.readLimits ?? (() => JSON.stringify(fake.limits ?? { limit_seconds: 60, cpu_limit_seconds: 10, exempt: {} })),
		print: (text) => out.push(text),
		error: (text) => out.push(text),
	};
	const status = await runSuite(io, wall);
	return { status, out: out.join(""), calls };
}

const b = "test/web/b_test.exs";
const judged = (runs: Run[], limits: unknown = overLimits) => ({ runs: { [b]: runs }, limits });

describe("runSuite", () => {
	test("compiles once, then runs every test file once, largest first, on half the cores' slots", async () => {
		const { status, out, calls } = await suite();
		expect(status).toBe(0);
		expect(out).toBe("mix test: all 3 test files passed.\n");
		expect(calls).toEqual(["compile", `2 ${b}`, "2 test/c_test.exs", "2 test/a_test.exs"]);
	});

	test("a failing compile fails the run with its status before any test file runs", async () => {
		const { status, calls } = await suite({ compile: 2 });
		expect(status).toBe(2);
		expect(calls).toEqual(["compile"]);
	});

	test("a failing file fails the run and has its output shown; every failing file is listed", async () => {
		const { status, out } = await suite({
			runs: { [b]: [fail(`ran ${b}\nerr ${b}\n`)], "test/a_test.exs": [fail("a failed\n")] },
		});
		expect(status).toBe(1);
		expect(out).toBe(
			`\n=== mix test ${b} ===\nran ${b}\nerr ${b}\n` +
				"\n=== mix test test/a_test.exs ===\na failed\n" +
				`\nmix test: 2 of 3 test files failed:\n  ${b}\n  test/a_test.exs\n`,
		);
	});

	test("a file that did not finish fails the run", async () => {
		const { status, out } = await suite({ runs: { [b]: [{ status: null, output: "", times: "" }] } });
		expect(status).toBe(1);
		expect(out).toBe(`\n=== mix test ${b} did not finish ===\n\nmix test: 1 of 3 test files failed:\n  ${b}\n`);
	});

	test("no file is run again, nor the limits read, once a file has failed", async () => {
		const { status, out, calls } = await suite({
			runs: { [b]: [fail("x\n")], "test/a_test.exs": [pass("9 9 9")] },
			readLimits: () => {
				throw new Error("read");
			},
		});
		expect(status).toBe(1);
		expect(out).not.toContain("running again");
		expect(calls).toHaveLength(4);
	});
});

describe("the per-file time limit", () => {
	test("a file still over the limit when run again fails the run and is named", async () => {
		const { status, out, calls } = await suite(judged([pass("2 1 1"), pass("2 0.9 0.3")]));
		expect(status).toBe(1);
		expect(out).toBe(
			"\nmix test: running again, after this run's other files, each test file over the 1 s CPU-time limit beside them:\n" +
				`  ${b}: 2.0 s beside others, 1.2 s run again\n` +
				`\nmix test: test files over the 1 s CPU-time limit for one file, run again:\n  ${b}: 1.2 s\n` +
				`Make each faster or split it. List one in ${LIMITS} only with a reason it must stay slow.\n`,
		);
		expect(calls.at(-1)).toBe(`2 ${b}`);
	});

	test("a file over the limit only beside others passes, run again once", async () => {
		const { status, out, calls } = await suite(judged([pass("2 1 1"), pass("2 0.5 0.5")]));
		expect(status).toBe(0);
		expect(out).toContain(`  ${b}: 2.0 s beside others, 1.0 s run again\n`);
		expect(out).toEndWith("mix test: all 3 test files passed.\n");
		expect(calls.filter((call) => call.endsWith(b))).toHaveLength(2);
	});

	test("time a file spends waiting does not count, but in CI it does", async () => {
		const waiting = () => judged([pass("3 0.1 0.1"), pass("3 0.1 0.1")]);
		const local = await suite(waiting());
		expect(local.status).toBe(0);
		expect(local.out).not.toContain("running again");

		const ci = await suite(waiting(), true);
		expect(ci.status).toBe(1);
		expect(ci.out).toContain(`test files over the 2 s wall-time limit for one file, run again:\n  ${b}: 3.0 s\n`);
	});

	test("a file that fails when run again fails the run and has its output shown", async () => {
		const { status, out } = await suite(judged([pass("2 1 1"), fail(`ran ${b}\n`)]));
		expect(status).toBe(1);
		expect(out).toContain(`  ${b}: 2.0 s beside others; failed when run again\n\n=== mix test ${b}, run again ===\nran ${b}\n`);
		expect(out).toContain("\nmix test: a test file run again failed.\n");
		expect(out).not.toContain("all 3 test files passed");
	});

	test("a file over the limit with a reason passes and is not run again", async () => {
		const exempt = { ...overLimits.exempt, [b]: { reason: "drives a real shell" } };
		const { status, out, calls } = await suite(judged([pass("9 9 9")], { ...overLimits, exempt }));
		expect(status).toBe(0);
		expect(out).toBe("mix test: all 3 test files passed.\n");
		expect(calls).toHaveLength(4);
	});

	test("a time exactly at the limit passes", async () => {
		const { status, out } = await suite(judged([pass("0 0.5 0.5")]));
		expect(status).toBe(0);
		expect(out).not.toContain("running again");
	});

	test("bad limits or times fail the run, naming the problem", async () => {
		const bad = await suite({ limits: { limit_seconds: 60, exempt: {} } });
		expect(bad.status).toBe(1);
		expect(bad.out).toBe(`mix test: ${LIMITS} needs a positive cpu_limit_seconds.\n`);

		const times = await suite(judged([pass("1.5 0.1")]));
		expect(times.status).toBe(1);
		expect(times.out).toBe(`mix test: cannot read the times of ${b}: "1.5 0.1"\n`);
	});
});

describe("parseLimits", () => {
	const limits = (text: string, wall = false) => () => parseLimits(() => text, wall);

	test("reads the limit for the mode and the exempt files", () => {
		const text = '{"limit_seconds": 60, "cpu_limit_seconds": 10, "exempt": {"test/a_test.exs": {"reason": "slow"}}}';
		expect(limits(text)()).toEqual({ limitSeconds: 10, exempt: new Set(["test/a_test.exs"]) });
		expect(limits(text, true)().limitSeconds).toBe(60);
	});

	// Each limit is needed in both modes, so a gate catches what CI would.
	for (const [name, text, message] of [
		[
			"an entry without a reason",
			'{"limit_seconds": 60, "cpu_limit_seconds": 10, "exempt": {"test/a_test.exs": {}}}',
			"entry test/a_test.exs needs a non-empty reason.",
		],
		[
			"an entry with a blank reason",
			'{"limit_seconds": 60, "cpu_limit_seconds": 10, "exempt": {"test/a_test.exs": {"reason": " "}}}',
			"entry test/a_test.exs needs a non-empty reason.",
		],
		["no CPU-time limit", '{"limit_seconds": 60, "exempt": {}}', "needs a positive cpu_limit_seconds."],
		["no wall-time limit", '{"cpu_limit_seconds": 10, "exempt": {}}', "needs a positive limit_seconds."],
		["a zero limit", '{"limit_seconds": 0, "cpu_limit_seconds": 10, "exempt": {}}', "needs a positive limit_seconds."],
		["no exempt object", '{"limit_seconds": 60, "cpu_limit_seconds": 10}', "needs an exempt object."],
		["malformed JSON", "{", `cannot read ${LIMITS}: `],
	]) {
		test(`${name} is refused in both modes`, () => {
			for (const wall of [false, true]) expect(limits(text, wall)).toThrow(`${LIMITS}`);
			for (const wall of [false, true]) expect(limits(text, wall)).toThrow(message);
		});
	}

	test("a missing limits file is refused", () => {
		expect(() => parseLimits(() => readFileSync(join(root, "missing.json"), "utf8"), false)).toThrow(
			`cannot read ${LIMITS}: ENOENT`,
		);
	});

	test("the repo's limits are 60 s of wall time and 10 s of CPU time, and every exempt file exists", () => {
		const read = () => readFileSync(join(root, LIMITS), "utf8");
		expect(parseLimits(read, true).limitSeconds).toBe(60);
		const { limitSeconds, exempt } = parseLimits(read, false);
		expect(limitSeconds).toBe(10);
		for (const file of exempt) expect(existsSync(join(root, file)), `${file} is exempt but does not exist`).toBe(true);
	});
});

describe("parseMs", () => {
	test("reads CPU time as user plus system, and wall time as real", () => {
		expect(parseMs("3.000000 0.250000 0.125000\n", false, "f")).toBe(375);
		expect(parseMs("3.000000 0.250000 0.125000\n", true, "f")).toBe(3000);
	});

	test("reads a decimal comma, and adds up exactly", () => {
		// Added as floats, 1.1 and 0.1 show as 1.3.
		expect(show(parseMs("0,5 1,1 0,1", false, "f"))).toBe("1.2");
	});

	test("refuses times it cannot read", () => {
		for (const times of ["", "1.5 x 0.1", "1.5 0.1", "1 1.5 0.1 0.1"]) {
			expect(() => parseMs(times, false, "f")).toThrow(`cannot read the times of f: "${times}"`);
		}
	});
});

test("show rounds up to a tenth of a second", () => {
	expect(show(1004)).toBe("1.1");
	expect(show(1000)).toBe("1.0");
});

test("jobCount is half the cores, at least one", () => {
	expect([1, 2, 3, 4, 18].map(jobCount)).toEqual([1, 1, 1, 2, 9]);
});

describe("pool", () => {
	for (const jobs of [1, 2, 5]) {
		test(`runs at most ${jobs} at once and keeps the items' order`, async () => {
			let running = 0;
			let most = 0;
			const results = await pool(["a", "b", "c", "d"], jobs, async (item) => {
				most = Math.max(most, ++running);
				await Bun.sleep(1);
				running--;
				return item.toUpperCase();
			});
			expect(results).toEqual(["A", "B", "C", "D"]);
			expect(most).toBe(Math.min(jobs, 4));
		});
	}
});
