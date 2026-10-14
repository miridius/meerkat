// The steps by which the diff toolbar gives up room when its content does
// not fit on one row, least important first. The page's CSS styles each
// step it finds in the toolbar's `data-squeeze`.
export const SQUEEZE_STEPS = ["version", "files", "conn", "counts", "view", "title", "base", "head", "wrap"];

// The fewest steps, taken in order, after which `fits` holds; all of them
// when it never does. `fits` is asked with the steps taken so far.
export function squeeze(fits: (taken: string[]) => boolean, steps = SQUEEZE_STEPS): string[] {
	for (let n = 0; n < steps.length; n++) {
		if (fits(steps.slice(0, n))) return steps.slice(0, n);
	}
	return steps;
}
