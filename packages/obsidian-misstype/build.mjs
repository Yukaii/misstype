// Builds the plugin into dist/ (main.js, manifest.json, styles.css: the three
// files Obsidian installs). The decoder assets are gzipped into build/assets/
// and embedded in main.js, so the plugin works offline with nothing to fetch.
//
//   node build.mjs                  assets from ../../site/public (script/build_site_assets.sh)
//   node build.mjs --assets <dir>   assets from another folder
//   node build.mjs --vault <vault>  also copy dist/ into <vault>/.obsidian/plugins/misstype/
import { build } from "esbuild";
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { join, resolve } from "node:path";

const here = new URL(".", import.meta.url).pathname;
const arg = (name) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : undefined;
};
const assetsDir = resolve(arg("--assets") ?? join(here, "../../site/public"));
const vault = arg("--vault");

const ASSETS = ["misstype.wasm", "lexicon.tsv", "toneless.tsv", "english.tsv", "homophone.bin"];
const missing = ASSETS.filter((name) => !existsSync(join(assetsDir, name)));
if (missing.length) {
  console.error(`Missing ${missing.join(", ")} in ${assetsDir}. Run script/build_site_assets.sh first.`);
  process.exit(1);
}
await mkdir(join(here, "build/assets"), { recursive: true });
for (const name of ASSETS) {
  await writeFile(join(here, "build/assets", `${name}.gz`), gzipSync(await readFile(join(assetsDir, name)), { level: 9 }));
}

const dist = join(here, "dist");
await mkdir(dist, { recursive: true });
await build({
  entryPoints: [join(here, "src/main.js")],
  bundle: true,
  format: "cjs",
  platform: "browser",
  target: "es2022",
  // Provided by Obsidian at run time.
  external: ["obsidian", "electron", "@codemirror/*", "@lezer/*"],
  loader: { ".gz": "binary" },
  // enable() reads import.meta.url only to find assets by URL; the plugin passes a loaded `ime` instead.
  logOverride: { "empty-import-meta": "silent" },
  outfile: join(dist, "main.js"),
  minify: true,
  legalComments: "eof",
  logLevel: "info",
});
await copyFile(join(here, "manifest.json"), join(dist, "manifest.json"));
await copyFile(join(here, "styles.css"), join(dist, "styles.css"));

if (vault) {
  const target = join(resolve(vault), ".obsidian/plugins/misstype");
  await mkdir(target, { recursive: true });
  for (const name of ["main.js", "manifest.json", "styles.css"]) await copyFile(join(dist, name), join(target, name));
  console.log(`Installed into ${target}; enable Misstype under Settings → Community plugins.`);
}
