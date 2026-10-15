// CI's dependency audit. `mix hex.audit` falls back to its cache when it
// cannot fetch a package's record from hex.pm, and with no cache it finds
// no advisories and passes. This fails such a run instead.
const audit = Bun.spawnSync(["mix", "hex.audit"], {
	stdout: "pipe",
	stderr: "pipe",
});
const stdout = audit.stdout.toString();
const stderr = audit.stderr.toString();
process.stdout.write(stdout);
process.stderr.write(stderr);

if (`${stdout}${stderr}`.includes("Failed to fetch record")) {
	console.error(
		"scripts/hex-audit.ts: Hex could not fetch every package's record, so the audit is incomplete.",
	);
	process.exit(1);
}
process.exit(audit.exitCode ?? 1);
