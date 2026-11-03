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
	"paste",
	"cut",
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
};

export function gateVerdict(e: GateEvent, target: GateTarget, focused: boolean): GateVerdict {
	switch (e.type) {
		// A press on a control or field that lacks focus would focus it;
		// a press elsewhere starts a selection, as it does when connected.
		case "mousedown":
			return target !== "other" && !focused ? "cancel" : "stop";
		// Tab moves focus. Other keys keep find, copy and scrolling: a key
		// that acts on a control does so by a `click` or `submit`, and a
		// text field's edits come as `beforeinput`, `paste` or `cut`.
		case "keydown":
			return e.key === "Tab" ? "cancel" : "stop";
		case "pointerdown":
		case "pointerup":
		case "mouseup":
		case "keyup":
			return "stop";
		default:
			return "cancel";
	}
}
