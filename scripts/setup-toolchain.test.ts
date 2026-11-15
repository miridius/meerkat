import { expect, test } from "bun:test";
import { needsInstall, pinIn } from "./setup-toolchain";

test("mise installs when it lists a pin as missing, or cannot list them", () => {
	expect(needsInstall(0, "")).toBe(false);
	expect(needsInstall(0, "\n")).toBe(false);
	expect(needsInstall(0, "elixir 1.20.5 (missing)\n")).toBe(true);
	expect(needsInstall(1, "")).toBe(true);
});

test("reads a pin from toolchain.env's text", () => {
	const env = "# pins\nHEX_VERSION=2.5.3\nREBAR3_VERSION=3.27.3\nREBAR3_SHA256=\n";
	expect(pinIn(env, "HEX_VERSION")).toBe("2.5.3");
	expect(pinIn(env, "REBAR3_VERSION")).toBe("3.27.3");
	expect(pinIn(env, "REBAR3_SHA256")).toBeUndefined();
	expect(pinIn(env, "VERSION")).toBeUndefined();
});
