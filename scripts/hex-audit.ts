// The Hex audit that check.ts and CI run. `mix hex.audit` falls back to
// its cache when it cannot fetch a package's record from hex.pm, and with
// no cache it finds no advisories and passes. This fails such a run
// instead. Hex reports a failed fetch on stderr.

// verdict STDERR CODE: the exit status for an audit that wrote STDERR and
// exited CODE, and why it fails a passing audit, if it does.
export function verdict(stderr: string, code: number | null): { code: number; why?: string } {
	if (stderr.includes("Failed to fetch record"))
		return {
			code: 1,
			why: "scripts/hex-audit.ts: Hex could not fetch every package's record, so the audit is incomplete.",
		};
	return { code: code ?? 1 };
}

if (import.meta.main) {
	const audit = Bun.spawnSync(["mix", "hex.audit"], {
		stdout: "inherit",
		stderr: "pipe",
	});
	const stderr = audit.stderr.toString();
	process.stderr.write(stderr);
	const { code, why } = verdict(stderr, audit.exitCode);
	if (why) console.error(why);
	process.exit(code);
}
