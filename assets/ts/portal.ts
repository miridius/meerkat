/** A Svelte action moving its node onto <body>, so no scroller clips it. */
export function portal(node: HTMLElement) {
	document.body.appendChild(node);
	return { destroy: () => node.remove() };
}
