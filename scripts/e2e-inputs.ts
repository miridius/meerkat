// Picks the lines of stdin that name a path the e2e suite may depend on.
// A line is a path, as `git diff --name-only` prints it, or a
// `git ls-tree` entry, whose path follows its tab.
//
//   e2e-inputs.ts         print those lines
//   e2e-inputs.ts --none  exit 0 if there are none, else 1
//
// --none answers "may the e2e steps be skipped?" with exit 0, so a crash
// runs them.
//
// The test is an allowlist of paths nothing in the e2e run reads or
// executes, leaving out this file, which decides when the run is skipped;
// every other path, a new one included, counts as an e2e input.
// scripts/check.ts skips the e2e steps of a commit that changes no e2e
// input, and scripts/checked-trees.ts --e2e keys its record on the e2e
// inputs alone. A path git quotes, for its unusual characters, matches
// nothing below and so counts as an input.

const notInputs: RegExp[] = [
	/\.md$/,
	// ExUnit tests; the e2e suite lives under tests/, but its fixture reads
	// test/support/test.gitconfig.
	/^test\/(?!support\/test\.gitconfig$)/,
	// No script here runs in the e2e suite, but check.ts runs the e2e steps
	// and sets their build environment, and this file decides when they may
	// be skipped.
	/^scripts\/(?!(check\.ts|e2e-inputs\.ts)$)/,
	// The toolchain.env pins pick the Hex and rebar3 that build the e2e run's
	// dependencies.
	/^\.github\/(?!toolchain\.env$)/,
	/^\.lefthook\//,
	/^lefthook\.yml$/,
	/^\.claude\//,
	/^\.worktreeinclude$/,
	/^\.formatter\.exs$/,
	/^biome\.json$/,
	/^LICENSE$/,
];

export const isInput = (line: string) => {
	const path = line.slice(line.indexOf("\t") + 1);
	return !notInputs.some((re) => re.test(path));
};

if (import.meta.main) {
	const inputs = (await Bun.stdin.text()).split("\n").filter((line) => line !== "" && isInput(line));

	if (process.argv[2] === "--none") process.exit(inputs.length === 0 ? 0 : 1);
	for (const line of inputs) console.log(line);
}
