// How many times slower than on an idle machine a wait may run. A review
// takes about 1 CPU-second to boot, yet at load 175 on 18 cores boots took
// over 40 s, so fixed idle-machine budgets failed tests that were only
// slow. Load can climb many-fold during a run, faster than the load
// average follows, so budgets do not scale with a load sample: they all
// allow the same fixed slowdown. A wait whose condition is met ends then,
// so a passing test is no slower; only a failing wait takes longer to fail.
const SLOWDOWN = 4;

// The wall-clock budget for a wait that `ms` covers on an idle machine.
export function budget(ms: number): number {
	return ms * SLOWDOWN;
}
