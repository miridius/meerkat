import { spawnSync } from "node:child_process";
import { makeFixture } from "./lib/fixture";
import { MEERKAT_BIN, startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

function runAnswers(
	cwd: string,
	input: string,
	flag = "--answers",
): { code: number | null; stderr: string } {
	const result = spawnSync(MEERKAT_BIN, [flag], {
		cwd,
		input,
		stdio: ["pipe", "ignore", "pipe"],
		timeout: 60_000,
		encoding: "utf8",
	});
	return { code: result.status, stderr: result.stderr };
}

test.describe("meerkat --answers", () => {
	test("stores answers from stdin and the next review pins them above the diff", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const input = JSON.stringify({
			answers: [
				{
					location: "src/main.rs:1 (new)",
					question: "Why the `use std::fmt`?",
					answer: "It backs the Display impl below.",
				},
			],
		});

		try {
			const stored = runAnswers(fixture.dir, input);
			expect(stored.code).toBe(0);
			expect(stored.stderr).toContain("meerkat: stored 1 answer.");

			const meerkat = await startMeerkat({ fixture });
			try {
				await page.goto(meerkat.url);
				const banner = page.locator("section.pending-answers");
				await expect(banner.getByRole("heading", { name: "Pending answers (1)" })).toBeVisible();
				await expect(banner.locator(".location")).toHaveText("src/main.rs:1 (new)");
				await expect(banner.locator(".question")).toContainText("Why the use std::fmt?");
				await expect(banner.locator(".answer")).toContainText("It backs the Display impl below.");
			} finally {
				await meerkat.kill();
			}
		} finally {
			fixture.cleanup();
		}
	});

	test("--answers=true reads stdin too, rather than an empty one", () => {
		const fixture = makeFixture();
		const input = JSON.stringify({
			answers: [{ location: "global", question: "why?", answer: "because" }],
		});

		try {
			const result = runAnswers(fixture.dir, input, "--answers=true");
			expect(result.code).toBe(0);
			expect(result.stderr).toContain("meerkat: stored 1 answer.");
		} finally {
			fixture.cleanup();
		}
	});

	test("a review target alongside --answers is a usage error", () => {
		const fixture = makeFixture();
		try {
			const result = spawnSync(MEERKAT_BIN, ["--answers", "HEAD"], {
				cwd: fixture.dir,
				input: "",
				stdio: ["pipe", "ignore", "pipe"],
				timeout: 60_000,
				encoding: "utf8",
			});
			expect(result.status).toBe(64);
			expect(result.stderr).toContain("--answers takes no review target");
		} finally {
			fixture.cleanup();
		}
	});

	test("rejects bad input with exit 1 and a message", () => {
		const fixture = makeFixture();
		try {
			const result = runAnswers(fixture.dir, '{"answers": []}');
			expect(result.code).toBe(1);
			expect(result.stderr).toContain("meerkat: --answers rejected:");
		} finally {
			fixture.cleanup();
		}
	});
});
