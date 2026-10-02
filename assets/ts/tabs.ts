// What a browser tab holds itself but every tab of the review shows:
// the scroll position and a line selection still being dragged. Like
// comment drafts, it lives in localStorage, which every tab of the
// review shares (they share its origin), under keys scoped to the
// review; the `storage` event tells the other tabs of each change, and
// a tab opening reads the current value.

export type DragRange = { side: "old" | "new"; lo: number; hi: number };

function key(name: string): string | null {
	if (typeof document === "undefined") return null;
	const reviewId = document.getElementById("meerkat-root")?.dataset.reviewId;
	return reviewId ? `meerkat:view:${reviewId}:${name}` : null;
}

export function readTabState<T>(name: string): T | null {
	const k = key(name);
	try {
		const raw = k ? localStorage.getItem(k) : null;
		return raw === null ? null : (JSON.parse(raw) as T);
	} catch {
		return null;
	}
}

// `null` clears it.
export function writeTabState(name: string, value: unknown): void {
	const k = key(name);
	if (!k) return;
	try {
		if (value === null) localStorage.removeItem(k);
		else localStorage.setItem(k, JSON.stringify(value));
	} catch {
		/* storage disabled: this tab's state stays its own */
	}
}

// Like `writeTabState`, for state that ends with this tab, such as a
// drag in progress: closing or reloading the tab clears it.
const heldUntilClose = new Set<string>();
export function holdTabState(name: string, value: unknown): void {
	writeTabState(name, value);
	if (value === null) heldUntilClose.delete(name);
	else heldUntilClose.add(name);
}
if (typeof window !== "undefined") {
	window.addEventListener("pagehide", () => {
		for (const name of heldUntilClose) writeTabState(name, null);
	});
}

// Calls `listener` when another tab changes it. Returns a function
// that stops listening.
export function onTabState<T>(name: string, listener: (value: T | null) => void): () => void {
	const k = key(name);
	if (!k) return () => {};
	const handler = (e: StorageEvent) => {
		if (e.key === k || e.key === null) listener(readTabState<T>(name));
	};
	window.addEventListener("storage", handler);
	return () => window.removeEventListener("storage", handler);
}
