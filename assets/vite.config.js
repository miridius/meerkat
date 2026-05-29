import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import liveSveltePlugin from "live_svelte/vitePlugin";

export default defineConfig({
  server: {
    port: 5173,
    strictPort: true,
    cors: { origin: "http://localhost:4000" },
  },
  optimizeDeps: {
    // Prebundle linked deps so Vite's dep resolution doesn't choke
    // on the `file:../deps/...` symlinks Phoenix gives us at build
    // time.
    include: ["live_svelte", "phoenix", "phoenix_html", "phoenix_live_view"],
  },
  ssr: { noExternal: process.env.NODE_ENV === "production" ? true : undefined },
  build: {
    manifest: true,
    rollupOptions: {
      input: ["js/app.js"],
    },
    outDir: "../priv/static",
    emptyOutDir: true,
  },
  resolve: {
    alias: {
      "@": ".",
      // Phoenix LiveView's colocated-JS feature lives under
      // MIX_BUILD_PATH/phoenix-colocated/<otp_app>. The launcher /
      // dev watcher exports MIX_BUILD_PATH so this resolves at
      // build time.
      "phoenix-colocated": `${process.env.MIX_BUILD_PATH}/phoenix-colocated`,
    },
  },
  plugins: [
    svelte({ compilerOptions: { css: "injected" } }),
    liveSveltePlugin({ entrypoint: "./js/server.js" }),
  ],
});
