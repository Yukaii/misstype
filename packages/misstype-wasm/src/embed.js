// Single-file entry for `<script type="module" src=".../embed.js">`: turns the
// IME on for every text field on the page, with assets (`misstype.wasm` and the
// lexicons) loaded from the same folder as this script.
//
//   <script type="module" src="https://example.com/misstype/embed.js"></script>
//
// Set `window.MISSTYPE_AUTO = false` before it loads to skip the automatic
// start and call `Misstype.enable({ ... })` yourself.
import { enable } from "./enable.js";

globalThis.Misstype = { enable };

if (globalThis.MISSTYPE_AUTO !== false) {
  const start = () => enable(globalThis.MISSTYPE_OPTIONS).then((instance) => {
    globalThis.Misstype.instance = instance;
    document.dispatchEvent(new CustomEvent("misstype:ready", { detail: instance }));
  }).catch((error) => console.error("Misstype could not start", error));
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
  else start();
}
