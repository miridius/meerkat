import { execFileSync } from "node:child_process";
import {
	chmodSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	symlinkSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { expect, test } from "./lib/test";

// The shepherd lives next to the dev launcher MEERKAT_BIN points at.
const SHEPHERD = join(dirname(process.env.MEERKAT_BIN ?? "bin/meerkat-beam"), "meerkat-shepherd");

// Run the prod shepherd against a fake release BEAM whose per-iteration exit
// codes are scripted via a counter file, and report the shepherd's own exit
// code plus how many times the BEAM ran. This pins the exit-code contract the
// whole feature rests on, which no mix/Playwright gate otherwise touches.
function runShepherd(exitCodes: number[]): { code: number; iterations: number } {
	const dir = mkdtempSync(join(tmpdir(), "meerkat-shep-"));
	try {
		const rel = join(dir, "rel");
		mkdirSync(join(rel, "bin"), { recursive: true });
		symlinkSync(rel, join(dir, "current"));
		writeFileSync(join(dir, "seq"), exitCodes.join(" "));
		writeFileSync(join(dir, "i"), "0");
		writeFileSync(
			join(rel, "bin", "meerkat"),
			`#!/usr/bin/env bash
i=$(cat "$I_FILE"); codes=($(cat "$SEQ_FILE"))
echo $((i + 1)) > "$I_FILE"
exit "\${codes[$i]:-0}"
`,
		);
		chmodSync(join(rel, "bin", "meerkat"), 0o755);

		let code = 0;
		try {
			execFileSync(SHEPHERD, ["--commit-msg", "/tmp/msg", "--no-open"], {
				env: {
					...process.env,
					MEERKAT_CURRENT_LINK: join(dir, "current"),
					MEERKAT_PORT: "44444",
					I_FILE: join(dir, "i"),
					SEQ_FILE: join(dir, "seq"),
				},
				stdio: "ignore",
				timeout: 10_000,
			});
		} catch (e) {
			code = (e as { status?: number }).status ?? -1;
		}

		return { code, iterations: Number(readFileSync(join(dir, "i"), "utf8").trim()) };
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}

test.describe("prod shepherd loop", () => {
	test("restarts on exit 75, then propagates a clean decision", () => {
		expect(runShepherd([75, 75, 0])).toEqual({ code: 0, iterations: 3 });
	});

	test("retries a crash (exit 2) once, then propagates a clean decision", () => {
		expect(runShepherd([2, 0])).toEqual({ code: 0, iterations: 2 });
	});

	test("aborts (propagates 2) on a second consecutive crash", () => {
		expect(runShepherd([2, 2])).toEqual({ code: 2, iterations: 2 });
	});

	test("propagates a reject (exit 1) straight through", () => {
		expect(runShepherd([1])).toEqual({ code: 1, iterations: 1 });
	});

	test("a 75 restart resets the crash budget", () => {
		expect(runShepherd([2, 75, 2, 0])).toEqual({ code: 0, iterations: 4 });
	});
});
