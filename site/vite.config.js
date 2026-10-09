import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync, writeFileSync, copyFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { defineConfig } from "vite";

const here = import.meta.dirname;

// Emits editor/sw.js and editor/manifest.webmanifest next to the built page:
// both need stable, unhashed URLs, and the service worker needs the list of
// built files (public/ is generated, so it can't hold them).
function editorPwa() {
  let outDir;
  return {
    name: "misstype-editor-pwa",
    apply: "build",
    configResolved(config) {
      outDir = resolve(config.root, config.build.outDir);
    },
    closeBundle() {
      const files = [];
      const walk = (dir) => {
        for (const name of readdirSync(dir)) {
          const full = join(dir, name);
          if (statSync(full).isDirectory()) {
            if (!["media", "en"].includes(name) || dir !== outDir) walk(full);
          } else files.push(relative(outDir, full).split("\\").join("/"));
        }
      };
      walk(outDir);
      const wanted = files.filter((f) => /\.(js|css|wasm|tsv|png|svg|webmanifest|html)$/.test(f)
        && !["editor/sw.js", "index.html"].includes(f));
      // The editor URL itself (".../editor/") is the navigation request.
      const precache = ["editor/", ...wanted];
      const hash = createHash("sha256");
      for (const f of wanted) hash.update(f).update(readFileSync(join(outDir, f)));
      const source = readFileSync(join(here, "editor/sw.template.js"), "utf8")
        .replace("__PRECACHE__", JSON.stringify(precache))
        .replace("__VERSION__", hash.digest("hex").slice(0, 12));
      writeFileSync(join(outDir, "editor/sw.js"), source);
      copyFileSync(join(here, "editor/manifest.webmanifest"), join(outDir, "editor/manifest.webmanifest"));
      copyFileSync(join(here, "editor/icon.png"), join(outDir, "editor/icon.png"));
    },
  };
}

// Static pages, no framework. Relative base so the build works on a
// GitHub Pages project URL (/misstype/) or a custom domain alike.
export default defineConfig({
  base: "./",
  plugins: [editorPwa()],
  resolve: {
    // The misstype-wasm package lives outside site/ and has no node_modules of its own.
    alias: { "@bjorn3/browser_wasi_shim": resolve(here, "node_modules/@bjorn3/browser_wasi_shim") },
  },
  server: { fs: { allow: [resolve(here, "..")] } },
  build: {
    // Keep the icon a cached file instead of inlining it into pages.
    assetsInlineLimit: 0,
    rollupOptions: {
      input: {
        main: resolve(here, "index.html"),
        en: resolve(here, "en/index.html"),
        editor: resolve(here, "editor/index.html"),
      },
    },
  },
});
