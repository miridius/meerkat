import { vitePreprocess } from "@sveltejs/vite-plugin-svelte";

// Svelte preprocess pipeline. `vitePreprocess` strips TS / SCSS /
// PostCSS via Vite's plugin chain — needed for `<script lang="ts">`
// blocks in components.
export default {
  preprocess: vitePreprocess(),
};
