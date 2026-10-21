// Light / dark for the page. `data-scheme` on <html> is the scheme in effect
// (style.css and the keyboard read it); the button in the nav cycles
// light → dark → auto and remembers the choice. The head snippet in each page
// sets data-scheme before first paint so a visitor never sees a flash.
// Until a choice is made the landing page is light; a page can say otherwise
// with data-theme-default on <html> (the editor follows the system: an app
// stuck in light mode at night is a bug report, not a style).
// theme-color follows the scheme in effect, not the system's: Safari and the
// installed app tint their bars with it, and a dark bar over a light page
// (or the other way round) looked like the page had ignored the setting.
const KEY = "misstype-theme";
const root = document.documentElement;
const query = matchMedia("(prefers-color-scheme: dark)");
const button = document.querySelector(".theme-toggle");
const ORDER = ["light", "dark", "auto"];
const fallback = ORDER.includes(root.dataset.themeDefault) ? root.dataset.themeDefault : "light";
const BAR = { light: "#f7f5f0", dark: "#0d0f14" };

const stored = () => {
  try { return localStorage.getItem(KEY); } catch { return null; }
};
let chosen = stored();
const mode = () => (ORDER.includes(chosen) ? chosen : fallback);

function apply() {
  const m = mode();
  root.dataset.scheme = m === "auto" ? (query.matches ? "dark" : "light") : m;
  for (const meta of document.querySelectorAll('meta[name="theme-color"]')) {
    meta.removeAttribute("media");
    meta.content = BAR[root.dataset.scheme];
  }
  if (button) {
    button.dataset.mode = m;
    button.setAttribute("aria-label", button.dataset[`label${m[0].toUpperCase()}${m.slice(1)}`] || m);
    button.title = button.getAttribute("aria-label");
  }
}

button?.addEventListener("click", () => {
  const next = ORDER[(ORDER.indexOf(mode()) + 1) % ORDER.length];
  chosen = next;
  try { localStorage.setItem(KEY, next); } catch { /* private mode: lasts until reload */ }
  apply();
});
query.addEventListener("change", apply);
apply();
