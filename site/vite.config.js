import { resolve } from "node:path";
import { defineConfig } from "vite";

// Static pages, no framework. Relative base so the build works on a
// GitHub Pages project URL (/misstype/) or a custom domain alike.
export default defineConfig({
  base: "./",
  build: {
    // Keep the icon a cached file instead of inlining it into pages.
    assetsInlineLimit: 0,
    rollupOptions: {
      input: {
        main: resolve(import.meta.dirname, "index.html"),
        en: resolve(import.meta.dirname, "en/index.html"),
      },
    },
  },
});
