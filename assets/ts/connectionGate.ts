// What the review page does with an input event while LiveView is not
// connected. LiveView drops every event pushed then, though a checkbox
// still ticks, so the page takes no clicks, focus or typing. It still
// lets the reader select, find, copy and scroll, which `inert` would not.

export const GATED_EVENTS = [
	"pointerdown",
	"mousedown",
	"pointerup",
	"mouseup",
	"click",
	"auxclick",
	"dblclick",
	"keydown",
	"keyup",
	"beforeinput",
	"submit",
	"drop",
] as const;

// `text`: a field that takes typing; `control`: any other element that
// takes focus; `other`: the rest of the page.
export type GateTarget = "text" | "control" | "other";

// `stop` keeps the page's own handlers from seeing the event; `cancel`
// also stops what the browser would do with it.
export type GateVerdict = "stop" | "cancel";

type GateEvent = {
	type: (typeof GATED_EVENTS)[number];
	key?: string;
	ctrlKey?: boolean;
	metaKey?: boolean;
};

export function gateVerdict(e: GateEvent, target: GateTarget, focused: boolean): GateVerdict {
	switch (e.type) {
		// Pressing on a control that lacks focus would move focus to it;
		// pressing on text starts a selection.
		case "mousedown":
			return target !== "other" && !focused ? "cancel" : "stop";
		// Tab moves focus, and a key on a checkbox, select or button acts
		// on it. Keys with Cmd or Ctrl keep find and copy, and a text
		// field's edits are stopped as `beforeinput`.
		case "keydown":
			if (e.key === "Tab") return "cancel";
			return target === "control" && !e.ctrlKey && !e.metaKey ? "cancel" : "stop";
		case "pointerdown":
		case "pointerup":
		case "mouseup":
		case "keyup":
			return "stop";
		default:
			return "cancel";
	}
}
