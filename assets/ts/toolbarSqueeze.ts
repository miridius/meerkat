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

type Mutation<N> = { type: string; target: N; addedNodes: Iterable<N>; removedNodes: Iterable<N> };

// Whether any of a MutationObserver's records can change the fit. The files
// dropdown sits out of the toolbar's flow, so nothing in it, nor its opening
// or closing, can; `inDropdown` says whether a node is, or is in, it.
export function changesFit<N>(records: Iterable<Mutation<N>>, inDropdown: (node: N) => boolean): boolean {
	for (const r of records) {
		if (inDropdown(r.target)) continue;
		if (r.type !== "childList" || ![...r.addedNodes, ...r.removedNodes].every(inDropdown)) return true;
	}
	return false;
}
