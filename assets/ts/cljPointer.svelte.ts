// The pointer side of Clojure hover (docs/features/clojure-hover.md) and
// go to definition (docs/features/clojure-go-to-definition.md), for one
// diff file or file view: a pointer resting on a symbol asks the server
// for its docs, Cmd (Ctrl off macOS) held over one asks where it is
// defined to underline it, and a Cmd-click or the popup's Go to link
// jumps there.

import {
	type CljHover,
	type CljJump,
	columnRects,
	HOVER_DELAY_MS,
	type HoverAnchor,
	type HoverSpot,
	isNavClick,
	keepsPopup,
	rescrolled,
	spotAt,
} from "./cljHover";
import { isMacPlatform } from "./sendFeedbackShortcut";

type Live = { pushEvent: (event: string, payload: unknown) => void };

/** The file requests name: a diff file, or a file view. */
export type CljFile = { file_index: number } | { where: string };

type Side = "old" | "new";

// Request ids, unique across every pointer on the page, since each one
// hears every answer.
let lastId = 0;

const HOVER_CLOSE_MS = 300;
// How long the pointer must rest, Cmd held, before the symbol under it
// is looked up: long enough to skip the symbols it sweeps past.
const LINK_DELAY_MS = 60;
const NOTE_MS = 1500;

const mac = () => typeof navigator !== "undefined" && isMacPlatform(navigator.platform);

type Box = { top: number; left: number; width: number; height: number };

export class CljPointer {
	/** The hover popup's var, where it opens, and the spot it was asked for. */
	shown = $state<{ hover: CljHover; anchor: HoverAnchor; row: string; spot: HoverSpot; side: Side } | null>(null);
	/** The symbol Cmd underlines, in window coordinates, and its jump. */
	link = $state<{ boxes: Box[]; jump: CljJump; spot: HoverSpot; side: Side } | null>(null);
	/** Where the `No definition found` note shows, in window coordinates. */
	note = $state<{ x: number; y: number } | null>(null);

	#live: Live;
	#file: () => CljFile;
	#side: (spot: HoverSpot) => Side;
	#jump: (jump: CljJump, side: Side) => void;
	#hoverTimer = 0;
	#closeTimer = 0;
	#linkTimer = 0;
	#noteTimer = 0;
	#hoverRequest: { id: number; anchor: HoverAnchor; row: string; spot: HoverSpot; side: Side } | null = null;
	// A definition request: to underline its symbol, or to jump there.
	#definitionRequest: { id: number; spot: HoverSpot; side: Side; go: { x: number; y: number } | null } | null =
		null;
	#pointer: { x: number; y: number } | null = null;

	/** `side` picks the side a spot reads as; `jump` takes the reviewer
	 *  to a definition. */
	constructor(live: Live, file: () => CljFile, side: (spot: HoverSpot) => Side, jump: (jump: CljJump, side: Side) => void) {
		this.#live = live;
		this.#file = file;
		this.#side = side;
		this.#jump = jump;
	}

	/** Listens for clicks on `el`, the file's code, the server's answers
	 *  and the Cmd key; returns the cleanup, for an effect to return. */
	listen(el: HTMLElement): () => void {
		const onClick = (e: MouseEvent) => this.#click(e);
		const onHover = (e: Event) => this.#onHover((e as CustomEvent).detail);
		const onDefinition = (e: Event) => this.#onDefinition((e as CustomEvent).detail);
		const onKey = (e: KeyboardEvent) => {
			if (e.key !== (mac() ? "Meta" : "Control")) return;
			if (e.type === "keydown" && this.#pointer) this.#lookUpSoon(this.#pointer.x, this.#pointer.y);
			else this.#unlink();
		};
		const unlink = () => this.#unlink();
		el.addEventListener("click", onClick);
		window.addEventListener("phx:clj:hover", onHover);
		window.addEventListener("phx:clj:definition", onDefinition);
		window.addEventListener("keydown", onKey);
		window.addEventListener("keyup", onKey);
		window.addEventListener("blur", unlink);
		// The underline sits in the window, so a scroll leaves it behind.
		window.addEventListener("scroll", unlink, { capture: true, passive: true });
		return () => {
			el.removeEventListener("click", onClick);
			window.removeEventListener("phx:clj:hover", onHover);
			window.removeEventListener("phx:clj:definition", onDefinition);
			window.removeEventListener("keydown", onKey);
			window.removeEventListener("keyup", onKey);
			window.removeEventListener("blur", unlink);
			window.removeEventListener("scroll", unlink, { capture: true });
			for (const t of [this.#hoverTimer, this.#closeTimer, this.#linkTimer, this.#noteTimer]) clearTimeout(t);
			// A file view that opens again starts with nothing showing.
			this.#hoverRequest = null;
			this.#definitionRequest = null;
			this.shown = null;
			this.link = null;
			this.note = null;
		};
	}

	/** A pointer move over the file; `dragging` while a comment drag runs. */
	move(e: PointerEvent, dragging: boolean) {
		this.#pointer = { x: e.clientX, y: e.clientY };
		clearTimeout(this.#hoverTimer);
		clearTimeout(this.#closeTimer);
		const { clientX: x, clientY: y } = e;
		this.#hoverTimer = window.setTimeout(() => this.#requestHover(dragging ? null : spotAt(x, y)), HOVER_DELAY_MS);
		if (isNavClick(e, mac()) && !dragging) this.#lookUpSoon(x, y);
		else this.#unlink();
	}

	/** The pointer left the file: the popup closes unless it moves onto it. */
	leave() {
		this.#pointer = null;
		this.#unlink();
		this.closeSoon();
	}

	// A Cmd-click on a symbol jumps to its definition.
	#click(e: MouseEvent) {
		if (!isNavClick(e, mac())) return;
		const spot = spotAt(e.clientX, e.clientY);
		if (!spot) return;
		e.preventDefault();
		const link = this.link;
		if (link && sameSymbol(link.spot, spot, link.jump)) {
			this.#unlink();
			this.#go(link.jump, link.side);
		} else {
			this.#requestDefinition(spot, { x: e.clientX, y: e.clientY });
		}
	}

	/** The popup's Go to link: jumps to the var it shows. */
	goToShown() {
		const shown = this.shown;
		if (!shown) return;
		const { left, bottom } = shown.anchor.rect;
		this.#requestDefinition(shown.spot, { x: left, y: bottom });
		this.shown = null;
	}

	closeSoon() {
		clearTimeout(this.#hoverTimer);
		clearTimeout(this.#closeTimer);
		this.#closeTimer = window.setTimeout(() => {
			this.#hoverRequest = null;
			this.shown = null;
		}, HOVER_CLOSE_MS);
	}

	keepOpen() {
		clearTimeout(this.#hoverTimer);
		clearTimeout(this.#closeTimer);
	}

	#requestHover(spot: HoverSpot | null) {
		if (!spot) {
			this.#hoverRequest = null;
			this.shown = null;
			return;
		}
		lastId += 1;
		const side = this.#side(spot);
		this.#hoverRequest = {
			id: lastId,
			anchor: { rect: spot.rect, scrollX: window.scrollX, scrollY: window.scrollY },
			row: `${side}:${spot.line}`,
			spot,
			side,
		};
		this.#live.pushEvent("clj.hover", { id: lastId, ...this.#file(), side, line: spot.line, col: spot.col });
	}

	#onHover({ id, hover }: { id: number; hover: CljHover | null }) {
		const request = this.#hoverRequest;
		if (id !== request?.id) return;
		const { anchor, row, spot, side } = request;
		if (keepsPopup(this.shown, row, hover)) return;
		// The page may have scrolled while the answer was on its way; the
		// popup picks its side by where the symbol is now.
		this.shown = hover ? { hover, anchor: rescrolled(anchor, window.scrollX, window.scrollY), row, spot, side } : null;
	}

	// Cmd held over a symbol: look it up once the pointer rests, unless
	// it is still on the symbol underlined.
	#lookUpSoon(x: number, y: number) {
		clearTimeout(this.#linkTimer);
		const spot = spotAt(x, y);
		const link = this.link;
		if (spot && link && sameSymbol(link.spot, spot, link.jump)) return;
		this.link = null;
		if (!spot) return;
		this.#linkTimer = window.setTimeout(() => this.#requestDefinition(spot, null), LINK_DELAY_MS);
	}

	#unlink() {
		clearTimeout(this.#linkTimer);
		if (!this.#definitionRequest?.go) this.#definitionRequest = null;
		this.link = null;
	}

	#requestDefinition(spot: HoverSpot, go: { x: number; y: number } | null) {
		lastId += 1;
		const side = this.#side(spot);
		this.#definitionRequest = { id: lastId, spot, side, go };
		this.#live.pushEvent("clj.definition", { id: lastId, ...this.#file(), side, line: spot.line, col: spot.col });
	}

	#onDefinition({ id, jump, other_side }: { id: number; jump: CljJump | null; other_side: boolean }) {
		const request = this.#definitionRequest;
		if (id !== request?.id) return;
		this.#definitionRequest = null;
		const { spot, side, go } = request;
		if (go) {
			if (jump) this.#go(jump, side);
			// A symbol only the other side defines does nothing, as hover.
			else if (!other_side) this.#showNote(go.x, go.y);
		} else if (jump && spot.raw.isConnected) {
			const boxes = columnRects(spot.raw, jump.col, jump.end_col).map(({ top, left, width, height }) => ({
				top,
				left,
				width,
				height,
			}));
			this.link = { boxes, jump, spot, side };
		}
	}

	// Jumps, closing the popup, which would cover where it lands.
	#go(jump: CljJump, side: Side) {
		clearTimeout(this.#hoverTimer);
		this.#hoverRequest = null;
		this.shown = null;
		this.#jump(jump, side);
	}

	#showNote(x: number, y: number) {
		clearTimeout(this.#noteTimer);
		this.note = { x, y };
		this.#noteTimer = window.setTimeout(() => {
			this.note = null;
		}, NOTE_MS);
	}
}

// Whether `spot` is on the symbol at `spot0` that `jump` spans.
function sameSymbol(spot0: HoverSpot, spot: HoverSpot, jump: CljJump): boolean {
	return spot.raw === spot0.raw && jump.col <= spot.col && spot.col < jump.end_col;
}
