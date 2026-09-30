import { describe, expect, test } from "bun:test";
import { countdownView } from "./countdown";

const now = 1_000_000;
const at = (secondsLeft: number) => countdownView(now + secondsLeft * 1000, now);

describe("countdownView", () => {
	test("counts the time left in minutes and seconds", () => {
		expect(at(1800).text).toBe("30:00 left");
		expect(at(61).text).toBe("01:01 left");
	});

	test("rounds a part-second left up", () => {
		expect(countdownView(now + 1500, now).text).toBe("00:02 left");
	});

	test("past the deadline, counts the time over", () => {
		expect(at(0).text).toBe("00:00 over");
		expect(at(-75).text).toBe("01:15 over");
	});

	test("is plain above five minutes, a warning down to 61 seconds, and urgent from one minute on", () => {
		expect(at(1800)).toMatchObject({ warn: false, urgent: false });
		expect(at(301)).toMatchObject({ warn: false, urgent: false });
		expect(at(300)).toMatchObject({ warn: true, urgent: false });
		expect(at(61)).toMatchObject({ warn: true, urgent: false });
		expect(at(60)).toMatchObject({ warn: false, urgent: true });
		expect(at(-75)).toMatchObject({ warn: false, urgent: true });
	});
});
