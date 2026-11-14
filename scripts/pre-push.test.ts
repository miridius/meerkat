import { describe, expect, test } from "bun:test";
import { plan, prePush, runChecks } from "../.lefthook/pre-push/pre-push";

const ZERO = "0".repeat(40);
const A = "a".repeat(40);
const B = "b".repeat(40);
const URL = "../remote.git";

describe("plan", () => {
	test("hands each new tip to the scan with the ref it goes to and the URL pushed to", () => {
		expect(plan(`refs/heads/x ${A} refs/heads/one ${ZERO}\nHEAD ${B} refs/heads/two ${A}\n`, URL)).toEqual({
			skip: false,
			tips: [A, B],
			scanArgs: ["--remote", URL, "--ref", "refs/heads/one", A, "--ref", "refs/heads/two", B],
		});
	});

	test("skips the checks, saying so, when every ref pushed is a deletion", () => {
		expect(plan(`(delete) ${ZERO} refs/heads/feature ${A}\n`, URL)).toEqual({
			skip: true,
			message: "pre-push: only deleting remote refs; skipping checks.",
		});
	});

	test("checks a push that deletes one branch and updates another", () => {
		const p = plan(`(delete) ${ZERO} refs/heads/feature ${A}\nHEAD ${B} refs/heads/other ${ZERO}\n`, URL);
		expect(p).toMatchObject({ skip: false, tips: [B] });
	});

	test("skips the checks silently for a push with nothing to send", () => {
		expect(plan("", URL)).toEqual({ skip: true });
	});
});

describe("runChecks", () => {
	const checks = (statuses: Record<string, number>) => {
		const ran: string[][] = [];
		const logged: string[] = [];
		const status = runChecks(
			plan(`HEAD ${A} refs/heads/f ${ZERO}\n`, URL),
			(cmd) => {
				ran.push(cmd);
				return statuses[cmd[1]] ?? 0;
			},
			(s) => logged.push(s),
		);
		return { status, ran: ran.map((cmd) => cmd[1]), logged };
	};

	test("runs both checks, then verified-push.ts with the tips", () => {
		const r = checks({});
		expect(r).toEqual({
			status: 0,
			ran: ["scripts/no-private-refs.ts", "scripts/outdated.ts", "scripts/verified-push.ts"],
			logged: [],
		});
	});

	test("a failing check blocks the push, the other still runs, and verified-push.ts does not", () => {
		expect(checks({ "scripts/no-private-refs.ts": 1 })).toMatchObject({
			status: 1,
			ran: ["scripts/no-private-refs.ts", "scripts/outdated.ts"],
		});
		expect(checks({ "scripts/outdated.ts": 1 })).toMatchObject({
			status: 1,
			ran: ["scripts/no-private-refs.ts", "scripts/outdated.ts"],
		});
	});

	test("a failing verified-push.ts blocks the push", () => {
		expect(checks({ "scripts/verified-push.ts": 2 }).status).toBe(1);
	});

	test("the scan asks the server pushed to, which git passes after the remote's name", () => {
		const ran: string[][] = [];
		prePush(["origin", URL], `HEAD ${A} refs/heads/f ${ZERO}\n`, (c) => ran.push(c) && 0, () => {});
		expect(ran[0]).toEqual(["bun", "scripts/no-private-refs.ts", "--remote", URL, "--ref", "refs/heads/f", A]);
	});

	test("a skipped push runs nothing", () => {
		const ran: string[][] = [];
		const logged: string[] = [];
		expect(runChecks(plan(`x ${ZERO} refs/heads/f ${A}\n`, URL), (c) => ran.push(c), (s) => logged.push(s))).toBe(0);
		expect(ran).toEqual([]);
		expect(logged).toEqual(["pre-push: only deleting remote refs; skipping checks."]);
	});
});
