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

// In the dark, every key press also sends a ring of colour across the whole
// page (the keyboard's own ring is in hairline/keys.js, which announces each
// press as `misstype:pulse` with the key's place on screen). It is drawn
// small on a fixed canvas and stretched by CSS, which makes it soft for free.
const SCALE = 0.2, LIFE = 2.4, SPEED = 900;
const rings = [];
let canvas, ctx, raf = 0, last = 0;

function sizeCanvas() {
  canvas.width = Math.ceil(innerWidth * SCALE);
  canvas.height = Math.ceil(innerHeight * SCALE);
}

function frame(now) {
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now;
  ctx.globalCompositeOperation = "source-over";
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.globalCompositeOperation = "lighter";
  for (let i = rings.length - 1; i >= 0; i--) {
    const r = rings[i];
    r.age += dt;
    const a = r.age / LIFE;
    if (a >= 1) { rings.splice(i, 1); continue; }
    const fade = (1 - a) ** 1.6, radius = r.age * SPEED * SCALE;
    const x = r.x * SCALE, y = r.y * SCALE, band = (120 + 260 * a) * SCALE;
    // The bloom behind the key.
    const core = ctx.createRadialGradient(x, y, 0, x, y, 340 * SCALE);
    core.addColorStop(0, `hsla(${r.hue} 100% 60% / ${0.34 * fade})`);
    core.addColorStop(1, `hsla(${r.hue} 100% 60% / 0)`);
    ctx.fillStyle = core;
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    // The ring: a rainbow band whose hue rolls on as it travels.
    const lo = Math.max(0, radius - band), hi = radius + band;
    const ring = ctx.createRadialGradient(x, y, lo, x, y, hi);
    ring.addColorStop(0, `hsla(${r.hue} 100% 60% / 0)`);
    ring.addColorStop(0.35, `hsla(${r.hue + 30} 100% 58% / ${0.2 * fade})`);
    ring.addColorStop(0.55, `hsla(${r.hue + 90} 100% 60% / ${0.26 * fade})`);
    ring.addColorStop(0.75, `hsla(${r.hue + 150} 100% 62% / ${0.16 * fade})`);
    ring.addColorStop(1, `hsla(${r.hue + 190} 100% 60% / 0)`);
    ctx.fillStyle = ring;
    ctx.fillRect(0, 0, canvas.width, canvas.height);
  }
  if (rings.length) raf = requestAnimationFrame(frame);
  else { raf = 0; ctx.clearRect(0, 0, canvas.width, canvas.height); }
}

document.addEventListener("misstype:pulse", (e) => {
  if (e.detail.calm || document.documentElement.dataset.scheme !== "dark") return;
  if (!canvas) {
    canvas = document.createElement("canvas");
    canvas.className = "page-glow";
    canvas.setAttribute("aria-hidden", "true");
    document.body.prepend(canvas);
    ctx = canvas.getContext("2d");
    sizeCanvas();
    addEventListener("resize", sizeCanvas);
  }
  rings.push({ x: e.detail.x, y: e.detail.y, hue: e.detail.hue, age: 0 });
  if (rings.length > 12) rings.shift();
  if (!raf) { last = performance.now(); raf = requestAnimationFrame(frame); }
});
