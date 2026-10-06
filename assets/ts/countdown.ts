// What the review footer's countdown shows `nowMs` against the review's
// deadline: the time left, or how long the review has run over, and
// whether that is close enough to style as a warning or as urgent.
export function countdownView(
	deadlineMs: number,
	nowMs: number,
): { text: string; warn: boolean; urgent: boolean } {
	const left = Math.ceil((deadlineMs - nowMs) / 1000);
	const secs = Math.abs(left);
	const mm = String(Math.floor(secs / 60)).padStart(2, "0");
	const ss = String(secs % 60).padStart(2, "0");
	return {
		text: left > 0 ? `${mm}:${ss} left` : `${mm}:${ss} over`,
		warn: left > 60 && left <= 300,
		urgent: left <= 60,
	};
}
