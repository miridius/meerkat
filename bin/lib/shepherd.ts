// Prod shepherd for meerkat. The installed `meerkat` wrapper sets
// MEERKAT_CURRENT_LINK (the install's `current` symlink) and execs this.
// It runs the release BEAM in a loop. The BEAM self-halts with code 75
// when its VersionWatcher sees `current` flip to a newer version; the
// shepherd re-resolves `current` and respawns, preferring the port the
// exited BEAM bound, so the browser's LiveView reconnects to the new
// version and ReviewServer reloads in-progress comments from the
// snapshot.
//
// What git (the blocked `git commit`) waits on is the caller in
// `attach.ts`, which starts this shepherd detached and relays its output
// and exit code. So the BEAM can be torn down and respawned underneath it
// without the commit ever ending, and the caller can exit without ending
// the review. A crash (exit 2) is retried once (state restored from the
// in-progress snapshot) before the commit aborts; a clean decision (76,
// passed on as 0, or 1) or a second crash reaches git through the caller,
// so the hook proceeds (0) or aborts.

import { accessSync, constants, readlinkSync } from "node:fs";
import { attach } from "./attach.ts";
import { CLI_HALT, requireAnswersInput, runOnce, say, selfCommand, serve, wantsAnswers } from "./serve.ts";

// The release `current` names, or an exit with 127 without one.
function resolveRelease(link: string): string {
	try {
		const release = readlinkSync(link);
		accessSync(`${release}/bin/meerkat`, constants.X_OK);
		return release;
	} catch {
		say(`meerkat: no current release at ${link}; re-run scripts/install.sh from the meerkat repo.\n`);
		process.exit(127);
	}
}

export async function main(args: string[]): Promise<never> {
	const link = process.env.MEERKAT_CURRENT_LINK;
	if (!link) {
		say("meerkat-shepherd: MEERKAT_CURRENT_LINK not set\n");
		process.exit(1);
	}
	process.env.MEERKAT_PWD ||= process.cwd();
	const beam = (release: string) => [`${release}/bin/meerkat`, "eval", CLI_HALT, ...args];

	// `--answers` reads the answers from stdin, so it runs once, with the
	// caller's stdin, with no retry to re-read a stdin already consumed.
	if (wantsAnswers(args)) {
		requireAnswersInput();
		return runOnce(beam(resolveRelease(link)));
	}

	// Run as the caller, which re-runs this shepherd detached, with
	// MEERKAT_SERVE_DIR set, to serve the review.
	if (!process.env.MEERKAT_SERVE_DIR) return attach(selfCommand(), args, process.env.MEERKAT_PWD);

	let release = "";
	let crashed = false;
	return serve({
		args,
		beforeEach() {
			release = resolveRelease(link);
		},
		beamCommand: () => beam(release),
		restarting: "meerkat: new version live; restarting...",
		// Crash (exit 2): retry once (the in-progress snapshot is restored on
		// the respawn), then abort so the commit fails closed. A restart
		// resets the budget.
		retry(code) {
			if (code === 75) crashed = false;
			if (code !== 2 || crashed) return false;
			crashed = true;
			say("meerkat: BEAM crashed (exit 2); respawning once before aborting...\n");
			return true;
		},
	});
}

// scripts/install.ts compiles this file into the installed shepherd:
// from an entry without a `.ts` extension, such as bin/meerkat-shepherd,
// `bun build --compile` bundles none of its imports and builds a binary
// that does nothing.
if (import.meta.main) await main(process.argv.slice(2));
