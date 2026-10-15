// The Hex audit that check.sh and CI run. `mix hex.audit` falls back to
// its cache when it cannot fetch a package's record from hex.pm, and with
// no cache it finds no advisories and passes. This fails such a run
// instead. Hex reports a failed fetch on stderr.
const audit = Bun.spawnSync(["mix", "hex.audit"], {
	stdout: "inherit",
	stderr: "pipe",
});
const stderr = audit.stderr.toString();
process.stderr.write(stderr);

if (stderr.includes("Failed to fetch record")) {
	console.error(
		"scripts/hex-audit.ts: Hex could not fetch every package's record, so the audit is incomplete.",
	);
	process.exit(1);
}
process.exit(audit.exitCode ?? 1);
