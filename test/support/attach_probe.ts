// A caller for `Meerkat.ShepherdTest`'s process chains: it records its
// ancestors with the real ps, says so in $MK_DIR/recorded, waits for the
// chain's top process, $MK_TOP, to exit, then gets a decision with exit
// code 1 from a stand-in backend and prints what it does to stdout. With
// $MK_HIDE set it hides every git from the ancestor walk, so a real git
// above the test run, as in a git hook, does not end the walk.

import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync, writeSync } from "node:fs";
import { join } from "node:path";
import { Caller, realDeps } from "../../bin/lib/attach.ts";

const dir = process.env.MK_DIR as string;
const top = Number(process.env.MK_TOP);
const out = (text: string) => writeSync(1, text);

const caller = new Caller(dir, "run", {
	...realDeps,
	ps(args) {
		const result = realDeps.ps(args);
		return process.env.MK_HIDE ? { ...result, out: result.out.replace(/git$/m, "tig") } : result;
	},
	stderr: out,
	async request(_method, url) {
		if (url.includes("attach/delivered")) out("delivered\n");
		return { status: 200, body: "", timedOut: false };
	},
	async stream(_url, _token, _signal, line) {
		for (const l of ["k", "o outcome", "x 1"]) line(l);
		return 200;
	},
});

caller.ancestors = caller.ancestorChain();
writeFileSync(join(dir, "recorded"), "");

const underTop = () => {
	for (let pid = process.pid; pid > 1; ) {
		const ppid = spawnSync("ps", ["-o", "ppid=", "-p", String(pid)], { encoding: "utf8" }).stdout.trim();
		pid = Number(ppid || 0);
		if (pid === top) return true;
	}
	return false;
};
const deadline = Date.now() + 60_000;
while (underTop()) {
	if (Date.now() > deadline) {
		out("the top process never exited\n");
		process.exit(1);
	}
	await Bun.sleep(50);
}

caller.dir = join(dir, "run.1");
mkdirSync(caller.dir);
writeFileSync(join(caller.dir, "port"), "4242 1\n");
writeFileSync(join(caller.dir, "token"), "token\n");
writeFileSync(join(caller.dir, "exit"), "1\n");
await caller.attachStream({});
