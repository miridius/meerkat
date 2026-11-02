// Installs the Hex archive and rebar3 that .github/toolchain.env pins
// into the Elixir on PATH, which a fresh Elixir lacks: `mix deps.get`
// would otherwise stop to ask. rebar3 is checked against REBAR3_SHA256.
// With mise, it first installs the Erlang, Elixir and Bun .tool-versions
// pins when mise lists one as missing, and the Elixir is the pinned one,
// whether or not mise is activated; a shim would otherwise install a new
// Elixir without its Hex. CI, the worktree setup hook, scripts/install.sh
// and scripts/bump-deps.sh run it; it does nothing when all are in place.

import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { $ } from "bun";

function pin(key: string): string {
	const value = readFileSync(".github/toolchain.env", "utf8").match(
		new RegExp(`^${key}=(.+)$`, "m"),
	)?.[1];
	if (!value) {
		console.error(`scripts/setup-toolchain.ts: .github/toolchain.env sets no ${key}.`);
		process.exit(1);
	}
	return value;
}

if (Bun.which("mise") && existsSync(".tool-versions")) {
	const tools = ["erlang", "elixir", "bun"];
	// Installs when mise cannot list what is missing too, so its failure shows.
	const missing = await $`mise ls --current --missing ${tools}`.nothrow().quiet();
	if (missing.exitCode !== 0 || missing.text().trim() !== "") {
		await $`mise install ${tools}`;
	}
	$.env({ ...process.env, ...JSON.parse(await $`mise env --json`.text()) });
}

const hex = pin("HEX_VERSION");
const rebar = pin("REBAR3_VERSION");
const rebarSha = pin("REBAR3_SHA256");
// Where this Elixir keeps archives and rebar3; mise gives each Elixir
// install its own MIX_HOME.
const [archives, installed] = (
	await $`elixir -e ${"IO.puts(Mix.path_for(:archives)); IO.puts(Mix.Rebar.local_rebar_path(:rebar3))"}`.text()
)
	.trim()
	.split("\n");

if (!existsSync(join(archives, `hex-${hex}`))) {
	await $`mix local.hex ${hex} --force`;
}

const sha256 = (file: string) => createHash("sha256").update(readFileSync(file)).digest("hex");

if (!existsSync(installed) || sha256(installed) !== rebarSha) {
	const dir = mkdtempSync(join(tmpdir(), "rebar3-"));
	try {
		const file = join(dir, "rebar3");
		await $`curl -fsSLo ${file} https://github.com/erlang/rebar3/releases/download/${rebar}/rebar3`;
		const sha = sha256(file);
		if (sha !== rebarSha) {
			console.error(`scripts/setup-toolchain.ts: rebar3 ${rebar} hashes to ${sha}, not ${rebarSha}.`);
			process.exitCode = 1;
		} else {
			await $`mix local.rebar rebar3 ${file} --force`;
		}
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}
