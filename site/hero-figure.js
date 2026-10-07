// The keyboard beside the hero (hairline/keys.js). The figure is written for
// the hairline-create bench, which defines a global `hairline()` that mounts
// it; this does the same into .hero-figure, and shows the key under the
// pointer in the corner. Without JS the space stays empty.
//
// The keyboard also follows typing: the demo animation announces each key it
// types as a `misstype:key` event ({ key, down }, key being a Zhuyin symbol),
// and real keys typed into the playground (inside .demo) press the key with
// the same KeyboardEvent.code.
import { HL } from "./hairline/kernel.js";

const host = document.querySelector(".hero-figure");
if (host) {
  const stage = host.querySelector(".stage");
  const label = host.querySelector(".read");
  globalThis.HL = HL;
  globalThis.hairline = (figure) => {
    HL.inject(document);
    stage.setAttribute("data-hairline", figure.name);
    const svg = HL.mk("svg", { viewBox: "0 0 400 320", "aria-hidden": "true" }, stage);
    const read = {
      set textContent(value) { label.textContent = value === "rest" ? "" : value; },
    };
    const handle = figure.mount({ stage, svg, read }, figure.range[1]);

    document.addEventListener("misstype:key", (e) => {
      if (e.detail.down) handle.press(e.detail.key);
      else handle.release(e.detail.key);
    });
    const fromDemo = (e) => e.target instanceof Element && e.target.closest(".demo");
    document.addEventListener("keydown", (e) => { if (fromDemo(e) && !e.isComposing) handle.press(e.code); }, true);
    document.addEventListener("keyup", (e) => { if (fromDemo(e)) handle.release(e.code); }, true);
    // A key released while the page was in the background never sends keyup.
    window.addEventListener("blur", () => handle.release());
  };
  import("./hairline/keys.js");
}
