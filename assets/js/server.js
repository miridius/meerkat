// SSR entry point — exports the `render(name, props)` live_svelte
// expects. Wired here so an SSR flip in config is a one-line change.
import { getRender } from "live_svelte";
import Components from "virtual:live-svelte-components";
export const render = getRender(Components);
