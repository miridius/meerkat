import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "./lib/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";

test.describe("PlantUML preview", () => {
	test("a deleted diagram previews its old side", async ({ page }) => {
		const fixture = makeFixture({ files: {} });
		try {
			writeFileSync(join(fixture.dir, "flow.puml"), "@startuml\nAlice -> Bob : hi\n@enduml\n");
			fixture.git("add", "flow.puml");
			fixture.git("commit", "-q", "-m", "add diagram");
			fixture.git("rm", "-q", "flow.puml");

			const meerkat = await startMeerkat({ fixture });
			try {
				await page.goto(meerkat.url);
				await expect(page.getByRole("button", { name: /^▾ D flow\.puml$/ })).toBeVisible();

				const preview = page.getByRole("region", { name: "PlantUML preview" });
				await expect(preview.getByText("Old", { exact: true })).toBeVisible();
				await expect(preview.getByText("New", { exact: true })).toHaveCount(0);

				const img = preview.getByRole("img", { name: "PlantUML diagram (Old side)" });
				await expect
					.poll(() => img.evaluate((el: HTMLImageElement) => el.naturalWidth))
					.toBeGreaterThan(0);
			} finally {
				await meerkat.kill();
			}
		} finally {
			fixture.cleanup();
		}
	});
});
