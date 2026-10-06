import { describe, expect, test } from "bun:test";
import { isMacPlatform, isSendFeedbackShortcut, sendFeedbackHint } from "./sendFeedbackShortcut";

const key = (mods: Partial<Parameters<typeof isSendFeedbackShortcut>[0]>) => ({
	key: "Enter",
	shiftKey: true,
	metaKey: false,
	ctrlKey: false,
	altKey: false,
	repeat: false,
	isComposing: false,
	...mods,
});

describe("isMacPlatform", () => {
	test("recognises Apple platforms only", () => {
		expect(isMacPlatform("MacIntel")).toBe(true);
		expect(isMacPlatform("macOS")).toBe(true);
		expect(isMacPlatform("iPad")).toBe(true);
		expect(isMacPlatform("Linux x86_64")).toBe(false);
		expect(isMacPlatform("Win32")).toBe(false);
		expect(isMacPlatform("")).toBe(false);
	});
});

describe("isSendFeedbackShortcut", () => {
	test("is Cmd+Shift+Enter on macOS and Ctrl+Shift+Enter elsewhere", () => {
		expect(isSendFeedbackShortcut(key({ metaKey: true }), true)).toBe(true);
		expect(isSendFeedbackShortcut(key({ ctrlKey: true }), false)).toBe(true);
		expect(isSendFeedbackShortcut(key({ ctrlKey: true }), true)).toBe(false);
		expect(isSendFeedbackShortcut(key({ metaKey: true }), false)).toBe(false);
	});

	test("needs Shift, so a comment form's Cmd/Ctrl+Enter is not it", () => {
		expect(isSendFeedbackShortcut(key({ metaKey: true, shiftKey: false }), true)).toBe(false);
		expect(isSendFeedbackShortcut(key({ ctrlKey: true, shiftKey: false }), false)).toBe(false);
	});

	test("rejects extra modifiers, other keys, auto-repeat and IME composition", () => {
		expect(isSendFeedbackShortcut(key({ metaKey: true, ctrlKey: true }), true)).toBe(false);
		expect(isSendFeedbackShortcut(key({ ctrlKey: true, metaKey: true }), false)).toBe(false);
		expect(isSendFeedbackShortcut(key({ metaKey: true, altKey: true }), true)).toBe(false);
		expect(isSendFeedbackShortcut(key({ metaKey: true, key: "a" }), true)).toBe(false);
		expect(isSendFeedbackShortcut(key({ metaKey: true, repeat: true }), true)).toBe(false);
		expect(isSendFeedbackShortcut(key({ metaKey: true, isComposing: true }), true)).toBe(false);
	});
});

describe("sendFeedbackHint", () => {
	test("uses macOS symbols on a Mac and spelled-out keys elsewhere", () => {
		expect(sendFeedbackHint(true)).toBe("⇧⌘↩");
		expect(sendFeedbackHint(false)).toBe("Ctrl+Shift+Enter");
	});
});
