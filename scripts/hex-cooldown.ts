// Marks the Hex rows a requirement excludes ("name latest not", one per
// line on stdin, from scripts/deps-common.sh's hex_outdated) as
// "cooldown" while hex.pm published that latest release under 24h ago,
// the cooldown mix.exs sets. Hex marks its cooldown only on a release the
// requirements admit, so hex.pm's publish time decides it for the rest.
// Prints every row, marked or not.
//
//   bun scripts/hex-cooldown.ts PREFIX < rows
//
// Exits 1, printing why after PREFIX, when hex.pm's record of a release
// cannot be read. HTTP goes through curl, so tests can stub it on PATH.

const DAY_MS = 86_400_000;
const prefix = process.argv[2] ?? "";

// published NAME VERSION: when hex.pm published it, or why that cannot be
// read.
async function published(name: string, version: string): Promise<Date | string> {
	const proc = Bun.spawn(["curl", "-sSf", "--max-time", "10", `https://hex.pm/api/packages/${name}`], {
		stdout: "pipe",
		stderr: "pipe",
	});
	const [body, err, code] = await Promise.all([
		new Response(proc.stdout).text(),
		new Response(proc.stderr).text(),
		proc.exited,
	]);
	if (code !== 0) return err.trim() || `curl exited ${code}`;
	let doc: { releases?: { version?: string; inserted_at?: string }[] };
	try {
		doc = JSON.parse(body);
	} catch (e) {
		return `hex.pm sent no JSON (${e instanceof Error ? e.message : e})`;
	}
	const date = new Date(String(doc?.releases?.find((r) => r.version === version)?.inserted_at));
	return Number.isNaN(date.getTime()) ? `hex.pm's record lists no publish time for ${version}` : date;
}

const rows = (await Bun.stdin.text()).split("\n").filter((line) => line.trim());
const out: string[] = [];
for (const row of rows) {
	const [name, latest, status] = row.trim().split(/\s+/);
	if (status !== "not") {
		out.push(row);
		continue;
	}
	const at = await published(name, latest);
	if (typeof at === "string") {
		console.error(
			`${prefix} could not read when hex.pm published ${name} ${latest} — cannot check Hex deps: ${at}`,
		);
		process.exit(1);
	}
	out.push(`${name} ${latest} ${Date.now() - at.getTime() < DAY_MS ? "cooldown" : "not"}`);
}
if (out.length) console.log(out.join("\n"));
