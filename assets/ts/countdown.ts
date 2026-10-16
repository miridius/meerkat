// What the review footer's countdown shows `nowMs` against the review's
// deadline: the time left, or how long the review has run over, and
// whether that is close enough to style as a warning or as urgent.
export function countdownView(
	deadlineMs: number,
	nowMs: number,
): { text: string; warn: boolean; urgent: boolean } {
	const left = Math.ceil((deadlineMs - nowMs) / 1000);
	const span = duration(Math.abs(left));
	return {
		text: left > 0 ? `${span} left` : `${span} over`,
		warn: left > 60 && left <= 300,
		urgent: left <= 60,
	};
}

// h:mm:ss at every length. Hours keep counting past a day: given days,
// the format reads "2 days, 20:28:17".
const clock = new Intl.DurationFormat("en", { style: "digital" });

function duration(secs: number): string {
	return clock.format({
		hours: Math.floor(secs / 3600),
		minutes: Math.floor(secs / 60) % 60,
		seconds: secs % 60,
	});
}
