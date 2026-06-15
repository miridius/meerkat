import { rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Page } from "@playwright/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// Wait for LiveView to finish joining — phx-click handlers aren't bound
// until the root view is `phx-connected`, and events fired before then
// are dropped silently. The `page` fixture's goto does this, but pages
// from `context.newPage()` don't, and each round needs a fresh page so a
// dead round's socket doesn't abort the next navigation.
async function gotoConnected(page: Page, url: string): Promise<void> {
	await page.goto(url);
	await page.waitForFunction(
		() =>
			document
				.querySelector("[data-phx-main]")
				?.classList.contains("phx-connected") === true,
		undefined,
		{ timeout: 45_000 },
	);
}

// A deletion's approval content-addresses against the HEAD pre-image
// (the content being removed). It once carried an empty `effective_oid`
// that the cache refused to store or re-hydrate, so the Approved tick
// was lost between rounds.
test.describe("approval persistence across review rounds", () => {
	test("an approved deletion stays ticked after the diff changes and meerkat reopens", async ({
		context,
	}) => {
		const fixture = makeFixture({ files: {} });
		const rounds: Array<{ kill: () => Promise<void> }> = [];
		try {
			// Seed two committed files, then stage: delete gone.rs, modify keep.rs.
			writeFileSync(join(fixture.dir, "gone.rs"), "fn gone() {}\n");
			writeFileSync(join(fixture.dir, "keep.rs"), "fn keep() -> i32 { 1 }\n");
			fixture.git("add", "gone.rs", "keep.rs");
			fixture.git("commit", "-q", "-m", "seed");

			fixture.git("rm", "-q", "gone.rs");
			writeFileSync(join(fixture.dir, "keep.rs"), "fn keep() -> i32 { 2 }\n");
			fixture.git("add", "keep.rs");

			const goneSection = (page: Page) =>
				page.locator("article.file-section", {
					has: page.getByRole("button", { name: /^▾ D gone\.rs$/ }),
				});

			// Round 1: tick the deletion, then wait for the server-rendered
			// `approved` class — the checkbox ticks optimistically client-
			// side, so it would pass before the toggle handler's cache
			// write lands, racing the kill below.
			const round1 = await startMeerkat({ fixture, keepFixture: true });
			rounds.push(round1);
			const page1 = await context.newPage();
			await gotoConnected(page1, round1.url);
			await goneSection(page1)
				.getByRole("checkbox", { name: "Approved" })
				.check();
			await expect(goneSection(page1)).toHaveClass(/\bapproved\b/);
			await round1.kill();

			// The agent reworks keep.rs but never touches the deletion. The
			// changed staged state discards any in-progress snapshot, so
			// round 2 re-hydrates approvals purely from the content cache.
			writeFileSync(join(fixture.dir, "keep.rs"), "fn keep() -> i32 { 3 }\n");
			fixture.git("add", "keep.rs");

			const round2 = await startMeerkat({ fixture, keepFixture: true });
			rounds.push(round2);
			const page2 = await context.newPage();
			await gotoConnected(page2, round2.url);

			const keepApprove = page2
				.locator("article.file-section", {
					has: page2.getByRole("button", { name: /^▾ M keep\.rs$/ }),
				})
				.getByRole("checkbox", { name: "Approved" });

			await expect(
				goneSection(page2).getByRole("checkbox", { name: "Approved" }),
			).toBeChecked();
			await expect(keepApprove).not.toBeChecked();
		} finally {
			// Reap any round left alive by a mid-test assertion failure.
			for (const round of rounds) await round.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});
});
