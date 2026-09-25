import { existsSync, readdirSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

const DEADLINES = [".git", "meerkat-precommit", "deadlines"];

function deadlinesDir(fixtureDir: string): string {
	return join(fixtureDir, ...DEADLINES);
}

async function waitForAnchor(fixtureDir: string): Promise<string[]> {
	const dir = deadlinesDir(fixtureDir);
	await expect.poll(() => existsSync(dir) && readdirSync(dir).length > 0).toBe(true);
	return readdirSync(dir);
}

// An anchor's start time is the epoch millisecond in its contents;
// its mtime is what `Timeout.prune_stale/1` reads. Move both, so the
// review looks old to whichever of the two decides its fate.
function backdate(fixtureDir: string, seconds: number): void {
	const dir = deadlinesDir(fixtureDir);
	const startedAt = Date.now() - seconds * 1000;
	const when = new Date(startedAt);
	for (const run of readdirSync(dir)) {
		const runDir = join(dir, run);
		for (const anchor of readdirSync(runDir)) {
			const path = join(runDir, anchor);
			writeFileSync(path, String(startedAt));
			utimesSync(path, when, when);
		}
		utimesSync(runDir, when, when);
	}
}

test.describe("the review timeout", () => {
	test("a review nobody answers exits 0 and says nobody read the diff when auto-approve is on", async ({
		page,
	}) => {
		const meerkat = await startMeerkat({
			env: { MEERKAT_REVIEW_TIMEOUT: "1", MEERKAT_AUTO_APPROVE_ON_TIMEOUT: "true" },
		});
		try {
			await page.goto(meerkat.url);
			await expect(
				page.locator(".review-countdown"),
				"the countdown's tooltip warns the commit will be auto-approved",
			).toHaveAttribute("title", /auto-approved unread/);

			const { code, stderr } = await meerkat.awaitExit();

			expect(code, "an unanswered review lets the commit proceed").toBe(0);
			expect(stderr, "the stderr line says the diff went unread").toContain(
				"Nobody read this diff",
			);
			expect(stderr, "the stderr line names the limit that ran out").toContain(
				"No review within 1 second:",
			);
		} finally {
			await meerkat.kill();
		}
	});

	test("a review nobody answers stays open and counts the time over when auto-approve is not on", async ({
		page,
	}) => {
		const meerkat = await startMeerkat({
			env: { MEERKAT_REVIEW_TIMEOUT: "1", MEERKAT_AUTO_APPROVE_ON_TIMEOUT: "maybe" },
		});
		try {
			await page.goto(meerkat.url);
			const countdown = page.locator(".review-countdown");
			await expect(
				countdown,
				"past the limit the countdown shows how long the review has run over",
			).toHaveText(/^\d{2}:\d{2} over$/);
			await expect(countdown, "an overdue countdown is styled urgent").toHaveClass(/\burgent\b/);
			await expect(
				countdown,
				"the countdown's tooltip says the review stays open",
			).toHaveAttribute("title", /stays open/);
			const overdueSeconds = async () => {
				const [mm, ss] = (await countdown.textContent())!.split(" ")[0].split(":");
				return Number(mm) * 60 + Number(ss);
			};
			const firstOver = await overdueSeconds();
			await expect
				.poll(overdueSeconds, { message: "the time over keeps growing" })
				.toBeGreaterThan(firstOver);

			// Two deadline ticks (15s each) plus slack.
			const exit = await Promise.race([
				meerkat.awaitExit().then(({ code }) => `exited with code ${code}`),
				page.waitForTimeout(35_000).then(() => null),
			]);
			expect(exit, "the review is still waiting for a human").toBeNull();

			await page.getByRole("button", { name: /^Approve$/ }).click();
			const { code, stderr } = await meerkat.awaitExit();
			expect(code, "the human's decision still ends an overdue review").toBe(0);
			expect(stderr, "the unrecognised setting is named on stderr").toContain(
				'MEERKAT_AUTO_APPROVE_ON_TIMEOUT="maybe"',
			);
		} finally {
			await meerkat.kill();
		}
	});

	test("each run of the launcher anchors its own deadline", async () => {
		const fixture = makeFixture();
		try {
			const first = await startMeerkat({ fixture, keepFixture: true });
			await waitForAnchor(fixture.dir);
			await first.kill();

			const second = await startMeerkat({ fixture, keepFixture: true });
			try {
				await expect
					.poll(() => readdirSync(deadlinesDir(fixture.dir)).length, {
						message: "the second run anchored under its own directory",
					})
					.toBe(2);

				const [one, two] = readdirSync(deadlinesDir(fixture.dir));
				expect(one, "the two runs are keyed apart").not.toBe(two);
			} finally {
				await second.kill();
			}
		} finally {
			fixture.cleanup();
		}
	});

	test("an anchor abandoned by an earlier run does not time out the next review", async ({
		page,
	}) => {
		const fixture = makeFixture();
		// Under the default wait action a review that inherited the
		// abandoned anchor would stay open too, and pass for the wrong reason.
		const env = { MEERKAT_REVIEW_TIMEOUT: "1800", MEERKAT_AUTO_APPROVE_ON_TIMEOUT: "true" };
		try {
			const abandoned = await startMeerkat({ fixture, keepFixture: true, env });
			await waitForAnchor(fixture.dir);
			await abandoned.kill();

			// An hour after the abandoned review opened, past the
			// 30 minute limit it was given.
			backdate(fixture.dir, 3600);

			const meerkat = await startMeerkat({ fixture, keepFixture: true, env });
			try {
				await page.goto(meerkat.url);
				await expect(page.getByRole("button", { name: /^Approve$/ })).toBeVisible();

				// A timeout exits the CLI without pushing a done view, so
				// the browser keeps rendering the open review either way.
				// Whether the process is still up is what separates them.
				// Two deadline ticks (15s each) plus slack.
				const exit = await Promise.race([
					meerkat.awaitExit().then(({ code }) => `exited with code ${code}`),
					page.waitForTimeout(35_000).then(() => null),
				]);

				expect(
					exit,
					"the review is still waiting for a human rather than auto-approved",
				).toBeNull();
			} finally {
				await meerkat.kill();
			}
		} finally {
			fixture.cleanup();
		}
	});
});
