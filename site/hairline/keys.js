/**
 * Keys: a small Zhuyin keyboard in a rounded case, four staggered rows and a
 * space bar. The pointer is projected onto the plane of the key tops, which
 * never moves; the key under it goes down, and its neighbours dip too, less
 * the farther they are: a fuzzy touch. At rest the last syllable typed,
 * ㄐㄧㄣ, is still sinking back, its final key down and bright. The slider is
 * the touch's spread, in keys.
 *
 * For the site, the handle also takes typing: press(key) and release(key),
 * the key named by its symbol or its KeyboardEvent.code, sink a key the way
 * a finger would, its neighbours dipping a little with it.
 *
 * Written to the hairline-create rules (github.com/lucasmarkes/hairline).
 */
const {
  Cam, clamp, facing, fit, hull, open, poly, proj, ringAt, rrect, run, seg, unproj,
  spring, stepS, mk, pointer, put, register, disposer, solid,
} = HL;

const U = 14, GAP = 3, KH = 10, DEPTH = 8.4, PB = 6, M = 7;
const OFF = [0, 0.5, 0.75, 1.25];
const ROWS = [
  "ㄅㄉˇˋㄓˊ˙ㄚㄞㄢ",
  "ㄆㄊㄍㄐㄔㄗㄧㄛㄟㄣ",
  "ㄇㄋㄎㄑㄕㄘㄨㄜㄠㄤ",
  "ㄈㄌㄏㄒㄖㄙㄩㄝㄡㄥ",
];
// The trail at rest: ㄐ, ㄧ, ㄣ, the last one still down.
const TRAIL = { "1,3": 0.3, "1,6": 0.55, "1,9": 1 };
const HOME = ["2,3", "2,6"];
// Each row's KeyboardEvent.code, in the same order as its symbols.
const CODES = [
  "Digit1 Digit2 Digit3 Digit4 Digit5 Digit6 Digit7 Digit8 Digit9 Digit0",
  "KeyQ KeyW KeyE KeyR KeyT KeyY KeyU KeyI KeyO KeyP",
  "KeyA KeyS KeyD KeyF KeyG KeyH KeyJ KeyK KeyL Semicolon",
  "KeyZ KeyX KeyC KeyV KeyB KeyN KeyM Comma Period Slash",
].map((r) => r.split(" "));
// The long keys a hand finds without looking, as [x0, x1] in keys, row, name, code.
const LONG = [
  [10, 11.25, 0, "bksp", "Backspace"], [0, 1.25, 3, "shift", "ShiftLeft"],
  [0, 1.25, 4, "ctrl", "ControlLeft"], [1.25, 2.4, 4, "opt", "AltLeft"], [2.4, 3.6, 4, "cmd", "MetaLeft"],
  [3.6, 8.6, 4, "space", "Space"], [8.6, 9.9, 4, "cmd", "MetaRight"], [9.9, 11.25, 4, "opt", "AltRight"],
];
// A typed key goes all the way; neighbours within one key's reach dip by up to this share.
const NEAR = 0.3;
const X1 = (10 + OFF[3]) * U, Y1 = 5 * U;

/** The share of the full press at u spreads from the pointer: 1 → 0 at the far end, never below. */
const falloff = (u) => (u >= 1 ? 0 : (1 - u) ** 1.7);

function mount({ stage, svg, read }, value) {
  const bag = disposer();
  const C = Cam(45, 0.5, 1.62);
  fit(C, [[-M, -M, -PB], [X1 + M, Y1 + M, -PB], [X1 + M, -M, -PB], [-M, Y1 + M, -PB], [-M, -M, KH], [X1 + M, -M, KH]], 200, 166);
  const P = proj(C), front = facing(C);
  let R = value * U, over = null;
  const held = new Set();
  let last = null;
  // RGB-keyboard colour: a press sends a ring of hue outward across the keys.
  // Each key's hue follows its column, so the same key is always the same
  // colour, and the ring drifts a little further round the wheel as it grows.
  const waves = [];
  const calm = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const WAVE_LIFE = 1.15, WAVE_SPEED = 7.5 * U, WAVE_WIDTH = 1.7 * U;
  const centre = (k) => [(k.x0 + k.x1) / 2, (k.y0 + k.y1) / 2];
  const hueOf = (k) => (centre(k)[0] / X1) * 300;
  /** Where a key's top sits on the page, for the glow behind the page. */
  function onScreen(k) {
    const [cx, cy] = centre(k), q = P(cx, cy, KH), m = svg.getScreenCTM();
    return m ? { x: m.a * q[0] + m.c * q[1] + m.e, y: m.b * q[0] + m.d * q[1] + m.f } : null;
  }
  function spawn(k) {
    const [x, y] = centre(k), hue = hueOf(k);
    if (!calm) waves.push({ x, y, hue, age: 0 });
    const at = onScreen(k);
    if (at) document.dispatchEvent(new CustomEvent("misstype:pulse", { detail: { ...at, hue, calm } }));
  }
  const dark = () => document.documentElement.dataset.scheme === "dark";

  const g = mk("g", {}, svg), keys = [];
  const [cr, ci] = [rrect(-M, -M, X1 + M, Y1 + M, 9, 14), rrect(-M + 2, -M + 2, X1 + M - 2, Y1 + M - 2, 7, 14)];
  put(solid(g), {
    sil: poly(hull(ringAt(P, cr, -PB).concat(ringAt(P, cr, 0)))),
    crease: open(ringAt(P, run(ci, front), 0)),
  });

  function addKey(x0, y0, x1, y1, name, id, code) {
    const foot = rrect(x0 + GAP / 2, y0 + GAP / 2, x1 - GAP / 2, y1 - GAP / 2, 2.6, 4);
    const top = rrect(x0 + 2.2, y0 + 2.2, x1 - 2.2, y1 - 2.2, 2, 4);
    const inner = rrect(x0 + 3, y0 + 3, x1 - 3, y1 - 3, 1.4, 4);
    const d0 = (TRAIL[id] ?? 0) * DEPTH;
    const k = { x0, y0, x1, y1, name, code, foot, top, inner, d0, sp: spring(d0, { eps: 0.02 }), el: solid(g), drawn: NaN, glow: 0 };
    if (HOME.includes(id)) k.bar = mk("path", { class: "nf lo" }, k.el.g);
    keys.push(k);
    return k;
  }
  // Row by row from the back, left to right: rows never straddle each other, so this is back to front.
  let rest = null;
  for (let j = 0; j < 5; j++) {
    const row = [...(ROWS[j] ?? "")].map((name, i) => [OFF[j] + i, OFF[j] + i + 1, name, j + "," + i, CODES[j][i]]);
    LONG.forEach(([a, b, r, name, code]) => { if (r === j) row.push([a, b, name, "", code]); });
    row.sort((p, q) => p[0] - q[0]).forEach(([a, b, name, id, code]) => {
      const k = addKey(a * U, j * U, b * U, (j + 1) * U, name, id, code);
      if (TRAIL[id] === 1) rest = k;
    });
  }
  let want = rest;

  function drawKey(k) {
    const h = KH - Math.max(0, k.sp.x);
    if (h !== k.drawn) {
      k.drawn = h;
      put(k.el, {
        sil: poly(hull(ringAt(P, k.foot, 0).concat(ringAt(P, k.top, h)))),
        crease: open(ringAt(P, run(k.inner, front), h)),
      });
      if (k.bar) {
        const cx = (k.x0 + k.x1) / 2, cy = k.y1 - 4.4;
        k.bar.setAttribute("d", seg(P(cx - 2.6, cy, h), P(cx + 2.6, cy, h)));
      }
    }
    k.el.sil.classList.toggle("hi", k === want);
  }

  /** Tint a key from the waves passing it and from its own depth; clear it when it fades. */
  function glowKey(k) {
    const [cx, cy] = centre(k);
    let g = Math.max(0, k.sp.x) / DEPTH * 0.9, hue = hueOf(k);
    for (const w of waves) {
      const d = Math.hypot(cx - w.x, cy - w.y), a = w.age / WAVE_LIFE;
      const ring = Math.exp(-(((d - WAVE_SPEED * w.age) / WAVE_WIDTH) ** 2)) * (1 - a) ** 1.4;
      if (ring > g) { g = ring; hue = w.hue + (d / U) * 11; }
    }
    g = g < 0.02 ? 0 : Math.min(1, g);
    const key = g === 0 ? 0 : Math.round(g * 40) * 1000 + Math.round(hue);
    if (key === k.glow) return;
    k.glow = key;
    const { sil, cr } = k.el;
    if (!g) { sil.style.cssText = cr.style.cssText = ""; return; }
    const lit = dark() ? 62 : 46, c = `hsl(${hue.toFixed(0)} 95% ${lit}%)`;
    sil.style.stroke = cr.style.stroke = c;
    sil.style.strokeWidth = `calc(var(--hl-sw) * ${(1 + g * 0.9).toFixed(2)})`;
    sil.style.fill = `color-mix(in srgb, var(--hl-plate), ${c} ${Math.round(g * (dark() ? 46 : 30))}%)`;
  }

  const B = register(stage, (dt) => {
    let m = false;
    for (const w of waves) w.age += dt;
    for (let i = waves.length - 1; i >= 0; i--) if (waves[i].age > WAVE_LIFE) waves.splice(i, 1);
    if (waves.length) m = true;
    for (const k of keys) { if (stepS(k.sp, dt)) m = true; drawKey(k); glowKey(k); }
    return m;
  });
  bag.add(B.unregister);

  /** World distance from the pointer to a key's resting footprint, 0 inside it. */
  const dist = (k, p) => Math.hypot(clamp(p[0], k.x0, k.x1) - p[0], clamp(p[1], k.y0, k.y1) - p[1]);

  /** Typing wins over the pointer while a key is held: each key sinks by the nearest held key's reach. */
  function typed() {
    for (const k of keys) {
      let t = 0;
      for (const h of held) {
        const c = [(h.x0 + h.x1) / 2, (h.y0 + h.y1) / 2];
        t = Math.max(t, h === k ? 1 : NEAR * clamp(falloff(dist(k, c) / U), 0, 1));
      }
      k.sp.t = DEPTH * t;
    }
    B.wake();
  }

  function retarget() {
    if (held.size) return typed();
    let best = null, bd = Infinity;
    if (over) for (const k of keys) { const d = dist(k, over); if (d < bd) { bd = d; best = k; } }
    if (!best || bd > U * 0.6) {
      // Before any typing, rest is the composed trail; after it, the last key typed keeps the bright.
      for (const k of keys) k.sp.t = last ? 0 : k.d0;
      want = last ?? rest; read.textContent = last ? last.name : "rest";
    } else {
      for (const k of keys) k.sp.t = DEPTH * clamp(falloff(dist(k, over) / R), 0, 1);
      best.sp.t = DEPTH;
      want = best; read.textContent = best.name;
    }
    B.wake();
  }

  bag.add(pointer(stage, {
    move: (p) => { over = unproj(C, p[0], p[1], KH); retarget(); },
    leave: () => { over = null; retarget(); },
  }));
  bag.add(() => svg.replaceChildren());

  const find = (key) => keys.find((k) => k.code === key || k.name === key);
  return {
    set: (v) => { R = v * U; if (over) retarget(); },
    press: (key) => {
      const k = find(key);
      if (!k) return;
      if (!held.has(k)) spawn(k);
      held.add(k); last = want = k; read.textContent = k.name;
      typed();
    },
    release: (key) => {
      const k = key == null ? null : find(key);
      if (k) held.delete(k); else if (key == null) held.clear();
      retarget();
    },
    destroy: bag.dispose,
  };
}

hairline({
  name: "keys",
  means: "A Zhuyin keyboard: the key under the pointer goes down, and its neighbours dip with it, less the farther they are.",
  rules: [1, 3, 5, 9],
  range: [0.6, 1.5, 2.4],
  mount,
});
