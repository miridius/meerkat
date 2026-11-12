import { describe, expect, test } from "bun:test";
import { check, gated, plan, type Step, steps, toRecord, withoutGitLocals } from "./check";
import type { Records, Store } from "./checked-trees";
import { fakeGit } from "./fake-git";

const ROOT = "/repo";

// Every check, in order, as `gated` logs its headers.
const ALL = [
	"mix deps.get",
	"bun scripts/hex-audit.ts",
	"pnpm audit",
	"pnpm install --frozen-lockfile --ignore-scripts --prefer-offline",
	"mix compile --warnings-as-errors",
	"mix format --check-formatted",
	"mix credo --strict",
	"bunx biome lint --error-on-warnings",
	"bash scripts/mix-test.sh",
	"bun test",
	"bun test tests/e2e/lib",
	"bun test scripts",
	"bun run build",
	"bunx playwright install --only-shell chromium",
	"bun run test:e2e",
];
const NO_E2E = ALL.slice(0, -3);

describe("plan", () => {
	test("skips a commit changing only Markdown, or nothing", () => {
		const skip = { skip: "pre-commit: no files other than Markdown changed; skipping checks." };
		expect(plan(false, "README.md\ndocs/guide.md\n")).toEqual(skip);
		expect(plan(false, "")).toEqual(skip);
	});

	// The diff lists a renamed file's old path, so renaming code to *.md
	// still runs the checks, and moving an e2e input under test/ runs the
	// e2e steps.
	test("checks a rename's old path", () => {
		expect(plan(false, "code.md\ncode.txt\n")).toEqual({ label: "pre-commit", e2e: true });
		expect(plan(false, "code.txt\ntest/code.txt\n")).toEqual({ label: "pre-commit", e2e: true });
	});

	test("skips the e2e steps of a commit changing no e2e input", () => {
		const tooling = "test/scripts/tool_test.exs\nscripts/tool.sh\n.github/workflows/ci.yml\n.lefthook/pre-push/pre-push.sh\n.claude/settings.json\n";
		expect(plan(false, tooling)).toEqual({ label: "pre-commit", e2e: false });
		expect(plan(false, `${tooling}new/thing.txt\n`)).toEqual({ label: "pre-commit", e2e: true });
	});

	test("checks HEAD with every step, whatever changed", () => {
		expect(plan(true, "")).toEqual({ label: "pre-push", e2e: true });
	});
});

describe("steps", () => {
	test("runs every check in the checkout root, in order", () => {
		const s = steps(ROOT, true);
		expect(s.map((x) => x.cmd.join(" "))).toEqual(ALL);
		const elsewhere = s.filter((x) => x.dir !== undefined || x.env !== undefined);
		expect(elsewhere).toEqual([
			{ cmd: ["bun", "test"], dir: "/repo/assets" },
			{ cmd: ["bun", "run", "build"], dir: "/repo/assets", env: { MIX_BUILD_PATH: "/repo/_build/dev" } },
		]);
	});

	test("leaves out the build and e2e steps when told to", () => {
		expect(steps(ROOT, false).map((x) => x.cmd.join(" "))).toEqual(NO_E2E);
	});
});

describe("withoutGitLocals", () => {
	test("drops each variable git names as local to the repository", () => {
		const env = { PATH: "/bin", GIT_DIR: "/r/.git", GIT_INDEX_FILE: "/r/.git/index.lock", GIT_WORK_TREE: "/r", GIT_PREFIX: "", GIT_EDITOR: "vi" };
		expect(withoutGitLocals(env, "GIT_DIR\nGIT_INDEX_FILE\nGIT_WORK_TREE\nGIT_PREFIX\n")).toEqual({ PATH: "/bin", GIT_EDITOR: "vi" });
	});
});

describe("toRecord", () => {
	const never = () => {
		throw new Error("looked up the e2e record");
	};

	test("records contents that passed every step as checked, e2e inputs included", () => {
		expect(toRecord(true, true, never)).toEqual(["e2e", "checked"]);
	});

	test("records contents that skipped the e2e steps as checked only if their e2e inputs passed them", () => {
		expect(toRecord(false, true, () => true)).toEqual(["checked"]);
		expect(toRecord(false, true, () => false)).toBe("unproven");
	});

	test("records nothing when the worktree did not hold the contents throughout", () => {
		expect(toRecord(true, false, never)).toEqual([]);
		expect(toRecord(false, false, never)).toEqual([]);
	});
});

describe("gated", () => {
	const HOOK_ENV = { PATH: "/bin", GIT_INDEX_FILE: "/repo/.git/index.lock", GIT_DIR: "/repo/.git" };

	// Runs the gated part with every step passing but `fail`, the worktree
	// holding the tree at each of `holding`'s checks (before, after), and the
	// e2e record `e2eRecorded`.
	const run = ({ e2e = true, fail = "", holding = [true, true], e2eRecorded = false, markFails = false } = {}) => {
		let checks = 0;
		const { g, ran } = fakeGit({ "rev-parse --local-env-vars": "GIT_DIR\nGIT_INDEX_FILE\n" });
		const git: typeof g = (args, opts) => {
			if (args[0] === "diff") {
				ran.push({ args: args.join(" "), ...opts });
				return { status: holding[checks++] ? 0 : 1, out: "" };
			}
			return args[0] === "ls-files" ? { status: 0, out: "" } : g(args, opts);
		};
		const marked: string[] = [];
		const records: Records = {
			has: (s: Store, t) => s === "e2e" && t === "tree1" && e2eRecorded,
			mark: (s: Store, t) => {
				marked.push(`${s} ${t}`);
				return !markFails;
			},
		};
		const out: string[] = [];
		const envs: Record<string, string | undefined>[] = [];
		const stepsRun: Step[] = [];
		const status = gated("pre-commit", "tree1", e2e, {
			git,
			records,
			root: ROOT,
			env: HOOK_ENV,
			run: (step, env) => {
				stepsRun.push(step);
				envs.push(env);
				return step.cmd.join(" ") === fail ? 1 : 0;
			},
			log: (l) => out.push(l),
		});
		return { status, marked, out: out.join("\n"), ran: stepsRun.map((s) => s.cmd.join(" ")), envs, gitRan: ran };
	};

	test("runs every check, records the contents, and says all passed", () => {
		const r = run();
		expect(r.status).toBe(0);
		expect(r.ran).toEqual(ALL);
		expect(r.marked).toEqual(["e2e tree1", "checked tree1"]);
		expect(r.out).toContain("\n=== pre-commit: mix credo --strict ===");
		expect(r.out.endsWith("\n=== pre-commit: all checks passed ===")).toBe(true);
	});

	test("runs the steps without git's hook variables, and checks the worktree after them the same way", () => {
		const r = run();
		expect(r.envs[0]).toEqual({ PATH: "/bin" });
		expect(r.envs[12]).toEqual({ PATH: "/bin", MIX_BUILD_PATH: "/repo/_build/dev" });
		// The first check, before the steps, reads the commit's own index.
		expect(r.gitRan.filter((x) => x.args.startsWith("diff")).map((x) => x.env)).toEqual([undefined, { PATH: "/bin" }]);
	});

	for (const [i, step] of ALL.entries()) {
		test(`a failing \`${step}\` stops the checks and records nothing`, () => {
			const r = run({ fail: step });
			expect(r.status).toBe(1);
			expect(r.ran).toEqual(ALL.slice(0, i + 1));
			expect(r.marked).toEqual([]);
			expect(r.out).not.toContain("all checks passed");
		});
	}

	test("records nothing when the worktree did not hold the tree before or after the steps", () => {
		expect(run({ holding: [false, true] })).toMatchObject({ status: 0, marked: [] });
		expect(run({ holding: [true, false] })).toMatchObject({ status: 0, marked: [] });
	});

	test("skipping the e2e steps says so", () => {
		const r = run({ e2e: false, e2eRecorded: true });
		expect(r.ran).toEqual(NO_E2E);
		expect(r.out).toContain("=== pre-commit: no e2e input changed; skipping the build and e2e steps ===");
		expect(r.marked).toEqual(["checked tree1"]);
	});

	test("contents whose e2e inputs never passed the e2e steps are left for the pre-push check", () => {
		const r = run({ e2e: false });
		expect(r.status).toBe(0);
		expect(r.marked).toEqual([]);
		expect(r.out).toContain("the pre-push check will run every check on a pushed tip that holds them");
	});

	test("fails when a record cannot be made", () => {
		expect(run({ markFails: true }).status).toBe(1);
	});
});

describe("check", () => {
	const run = (args: string[], answers: Parameters<typeof fakeGit>[0]) => {
		const out: string[] = [];
		const gates: string[] = [];
		const { g, ran } = fakeGit(answers);
		const status = check(args, {
			git: g,
			log: (l) => out.push(l),
			gate: (label, tree, e2e) => {
				gates.push(`${label} ${tree} ${e2e}`);
				return 7;
			},
		});
		return { status, out, gates, ran: ran.map((r) => r.args) };
	};

	test("gates the commit's contents, from the index git hands the hook", () => {
		const r = run([], { "diff --cached --no-renames --name-only": "code.txt\n", "write-tree": "t1\n" });
		expect(r).toEqual({ status: 7, out: [], gates: ["pre-commit t1 true"], ran: ["diff --cached --no-renames --name-only", "write-tree"] });
	});

	test("skips a Markdown-only commit without waiting for a gate slot", () => {
		const r = run([], { "diff --cached --no-renames --name-only": "README.md\n" });
		expect(r).toMatchObject({ status: 0, gates: [], out: ["pre-commit: no files other than Markdown changed; skipping checks."] });
	});

	test("with --head gates HEAD's tree, resolved before the slot is taken", () => {
		const r = run(["--head"], { "rev-parse --verify HEAD^{tree}": "t2\n" });
		expect(r).toMatchObject({ status: 7, gates: ["pre-push t2 true"], ran: ["rev-parse --verify HEAD^{tree}"] });
	});

	test("fails when git cannot list the changes or name the tree", () => {
		expect(run([], {}).status).toBe(1);
		expect(run([], { "diff --cached --no-renames --name-only": "code.txt\n" }).status).toBe(1);
		expect(run(["--head"], {}).status).toBe(1);
	});
});
