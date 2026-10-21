import { availableParallelism, loadavg } from "node:os";

// How many times slower than on an idle machine work runs at a one-minute
// load average of `load` on `cores` cores: the load per core, from 1 to 4.
export function slowdown(load: number, cores: number): number {
	return Math.min(4, Math.max(1, load / cores));
}

// The suite's slowdown, taken when the run starts. A review takes about
// 1 CPU-second to boot, yet at load 175 on 18 cores boots took over 40 s,
// so fixed budgets failed tests that were only slow. The first process to
// load this sets it in the environment, which the Playwright workers
// inherit, so every budget in a run scales alike.
const KEY = "MEERKAT_E2E_SLOWDOWN";
process.env[KEY] ??= String(slowdown(loadavg()[0], availableParallelism()));
const SLOWDOWN = Number(process.env[KEY]);

// The wall-clock budget for a wait that `ms` covers on an idle machine. A
// hang still fails, after at most four times `ms`.
export function budget(ms: number): number {
	return Math.round(ms * SLOWDOWN);
}
