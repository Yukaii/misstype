// Decoder assets, gzipped and embedded by build.mjs (esbuild's binary loader
// turns each import into a Uint8Array), so nothing is downloaded at run time.
import wasm from "../build/assets/misstype.wasm.gz";
import lexicon from "../build/assets/lexicon.tsv.gz";
import toneless from "../build/assets/toneless.tsv.gz";
import english from "../build/assets/english.tsv.gz";
import homophone from "../build/assets/homophone.bin.gz";
import { gunzip } from "./gunzip.js";

/** The assets in the shape `MisstypeWasm.fromBytes` takes. */
export async function loadAssets() {
  const text = async (bytes) => new TextDecoder().decode(await gunzip(bytes));
  const [w, l, t, e, h] = await Promise.all([gunzip(wasm), text(lexicon), text(toneless), text(english), gunzip(homophone)]);
  return { wasm: w, lexicon: l, toneless: t, english: e, homophone: h };
}
