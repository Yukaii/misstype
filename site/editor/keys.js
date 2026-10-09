// Key helpers shared by the IME bridge and the app shortcuts.
export const isApple = /Mac|iPhone|iPad|iPod/.test(navigator.platform || "")
  || (/Mac/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);

export const modLabel = isApple ? "⌘" : "Ctrl+";
export const shiftLabel = isApple ? "⇧" : "Shift+";

// Decoder modifier bits: Shift=1, Control=2, Alt=4, Meta=8, CapsLock=16.
export function modifierBits(e) {
  return (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0)
    | (e.metaKey ? 8 : 0) | (e.getModifierState?.("CapsLock") ? 16 : 0);
}

export const hasMod = (e) => (isApple ? e.metaKey : e.ctrlKey);

/** "Mod-Shift-p" style matcher; letters compare by physical code. */
export function matches(e, combo) {
  const parts = combo.split("-");
  const key = parts.pop();
  const want = { mod: false, shift: false, alt: false };
  for (const p of parts) want[p.toLowerCase()] = true;
  if (hasMod(e) !== want.mod) return false;
  if (e.shiftKey !== want.shift || e.altKey !== want.alt) return false;
  if (!isApple && !want.mod && e.ctrlKey) return false;
  return key.length === 1 && /[a-z]/i.test(key)
    ? e.code === `Key${key.toUpperCase()}`
    : e.key === key || e.code === key;
}

export function chord(combo) {
  return combo.split("-").map((p) => ({ Mod: modLabel.replace("+", ""), Shift: shiftLabel.replace("+", ""), Alt: isApple ? "⌥" : "Alt" }[p]
    ?? (p.length === 1 ? p.toUpperCase() : p))).join(isApple ? "" : "+");
}
