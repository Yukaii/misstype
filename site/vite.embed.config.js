import { resolve } from "node:path";
import { defineConfig } from "vite";

// The drop-in script for other websites: one self-contained ES module,
// dist/embed.js (the wasm shim bundled in), served next to misstype.wasm and the
// lexicons so it can find them by its own URL. Built after the pages by
// `npm run build`, into the same dist/ without emptying it.
const here = import.meta.dirname;

export default defineConfig({
  publicDir: false,
  resolve: {
    alias: { "@bjorn3/browser_wasi_shim": resolve(here, "node_modules/@bjorn3/browser_wasi_shim") },
  },
  build: {
    outDir: "dist",
    emptyOutDir: false,
    lib: { entry: resolve(here, "../packages/misstype-wasm/src/embed.js"), formats: ["es"], fileName: () => "embed.js" },
  },
});
