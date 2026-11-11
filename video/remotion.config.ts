import path from "node:path";
import { Config } from "@remotion/cli/config";

// Each worker tab is a full Chromium page; keep it modest on a laptop.
Config.setConcurrency(4);
Config.setVideoImageFormat("jpeg");
Config.setJpegQuality(92);

// src/decoder.ts imports the binding from packages/misstype-wasm, which has
// no node_modules of its own in a fresh clone: resolve its WASI shim here
// (site/vite.config.js does the same).
Config.overrideWebpackConfig((config) => ({
  ...config,
  resolve: {
    ...config.resolve,
    alias: {
      ...(config.resolve?.alias as Record<string, string> | undefined),
      "@bjorn3/browser_wasi_shim": path.resolve(process.cwd(), "node_modules/@bjorn3/browser_wasi_shim"),
    },
  },
}));
