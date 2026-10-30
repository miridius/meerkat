// How many times slower than on an idle machine a wait may run. A review
// takes about 1 CPU-second to boot, yet at load 175 on 18 cores boots took
// over 40 s, so fixed idle-machine budgets failed tests that were only
// slow. Load can climb many-fold during a run, faster than the load
// average follows, so budgets do not scale with a load sample: they all
// allow the worst slowdown. A passing wait ends when its condition is met,
// so this costs only a hang, which still fails.
const SLOWDOWN = 4;

// The wall-clock budget for a wait that `ms` covers on an idle machine.
export function budget(ms: number): number {
	return ms * SLOWDOWN;
}
