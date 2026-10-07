// The review footer's Send Feedback shortcut: Cmd+Shift+Enter on macOS,
// Ctrl+Shift+Enter elsewhere. Shift keeps it apart from a comment form's
// Cmd/Ctrl+Enter submit.

type ShortcutKey = Pick<
	KeyboardEvent,
	"key" | "shiftKey" | "metaKey" | "ctrlKey" | "altKey" | "repeat" | "isComposing"
>;

export function isMacPlatform(platform: string): boolean {
	return /mac|iphone|ipad|ipod/i.test(platform);
}

export function isSendFeedbackShortcut(e: ShortcutKey, mac: boolean): boolean {
	return (
		e.key === "Enter" &&
		e.shiftKey &&
		!e.altKey &&
		(mac ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey) &&
		!e.repeat &&
		!e.isComposing
	);
}

// macOS menus write modifiers in the order Shift, Command.
export function sendFeedbackHint(mac: boolean): string {
	return mac ? "⇧⌘↩" : "Ctrl+Shift+Enter";
}
