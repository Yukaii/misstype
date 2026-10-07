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
    const k = { x0, y0, x1, y1, name, code, foot, top, inner, d0, sp: spring(d0, { eps: 0.02 }), el: solid(g), drawn: NaN };
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

  const B = register(stage, (dt) => {
    let m = false;
    for (const k of keys) { if (stepS(k.sp, dt)) m = true; drawKey(k); }
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
