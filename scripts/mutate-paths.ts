// Refuses each path given to `scripts/mutate.sh <path…>` that is not an
// existing lib/**/*.ex file. muex finds nothing to mutate in such a path,
// writes no report, and the run would pass with no mutant judged.
import { statSync } from "node:fs";

const bad = process.argv.slice(2).filter((path) => {
	if (!/^lib\/.*\.ex$/.test(path)) return true;
	try {
		return !statSync(path).isFile();
	} catch {
		return true;
	}
});

for (const path of bad) {
	console.error(`scripts/mutate.sh: ${path} is not a lib/**/*.ex file.`);
}
process.exit(bad.length === 0 ? 0 : 2);
