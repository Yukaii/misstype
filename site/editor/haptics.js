// Key-press haptics for the on-screen keyboard.
//  - Android (Chrome): the Vibration API.
//  - iOS Safari has no Vibration API, but 17.4+ plays the system haptic when a
//    `<input type="checkbox" switch>` is toggled, so a hidden one is clicked
//    from the touch handler. Undocumented; it silently does nothing if Safari
//    changes it. Both need a user gesture, which a key press is.
const vibrates = typeof navigator.vibrate === "function";
const iosSwitch = !vibrates && /iPhone|iPad|iPod|Macintosh/.test(navigator.userAgent)
  && navigator.maxTouchPoints > 1 && typeof CSS !== "undefined" && CSS.supports?.("-webkit-touch-callout", "none");

let label = null;
function switchLabel() {
  if (label) return label;
  label = document.createElement("label");
  label.setAttribute("aria-hidden", "true");
  label.style.cssText = "position:fixed;left:-100px;top:-100px;width:1px;height:1px;opacity:0;pointer-events:none";
  const input = document.createElement("input");
  input.type = "checkbox";
  input.setAttribute("switch", "");
  input.tabIndex = -1;
  label.append(input);
  document.body.append(label);
  return label;
}

export const hapticsSupported = vibrates || iosSwitch;

/** One short tick; a no-op where the platform has no way to produce it. */
export function tick() {
  if (vibrates) navigator.vibrate(8);
  else if (iosSwitch) switchLabel().click();
}
