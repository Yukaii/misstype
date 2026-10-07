// The keyboard beside the hero (hairline/keys.js). The figure is written for
// the hairline-create bench, which defines a global `hairline()` that mounts
// it; this does the same into .hero-figure, and shows the key under the
// pointer in the corner. Without JS the space stays empty.
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
    figure.mount({ stage, svg, read }, figure.range[1]);
  };
  import("./hairline/keys.js");
}
