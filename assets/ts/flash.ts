// The flash that marks where a jump lands: a moved line's arrow, or go
// to definition. An inset shadow, so it shows over a cell's opaque
// background; held for 60% of the flash, then eased out.

const SHADOW = "inset 0 0 0 100vmax rgba(88, 166, 255, 0.35)";

export const FLASH_KEYFRAMES: Keyframe[] = [
	{ boxShadow: SHADOW, offset: 0 },
	{ boxShadow: SHADOW, offset: 0.6, easing: "ease-out" },
];

export const FLASH_MS = 1600;
