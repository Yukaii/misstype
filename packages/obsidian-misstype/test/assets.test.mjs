// The embedding pipeline end to end: build.mjs's gzipped assets, bundled with
// esbuild's binary loader as main.js is, decode and drive the real decoder.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = new URL("..", import.meta.url).pathname;

test("embedded assets load into the decoder", { skip: !existsSync(join(here, "build/assets/lexicon.tsv.gz")) && "run npm run build first" }, async () => {
  const dir = await mkdtemp(join(tmpdir(), "misstype-obsidian-"));
  try {
    const outfile = join(dir, "entry.mjs");
    await build({
      stdin: {
        contents: 'export { loadAssets } from "./src/assets.js"; export { default as MisstypeWasm } from "misstype-wasm";',
        resolveDir: here,
      },
      bundle: true, format: "esm", platform: "node", loader: { ".gz": "binary" }, outfile, logLevel: "silent",
    });
    const { loadAssets, MisstypeWasm } = await import(pathToFileURL(outfile).href);
    const assets = await loadAssets();
    assert.ok(assets.lexicon.length > 1_000_000, "full lexicon, not the test fixture");
    const ime = await MisstypeWasm.fromBytes(assets);
    for (const key of "su3cl3") ime.key(/[0-9]/.test(key) ? `Digit${key}` : `Key${key.toUpperCase()}`, key);
    assert.equal(ime.state().preedit, "你好");
    // Toneless and typo repair come from the embedded toneless table and homophone model.
    ime.reset();
    for (const key of "sucl") ime.key(`Key${key.toUpperCase()}`, key);
    assert.equal(ime.state().candidates[0], "你好");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
