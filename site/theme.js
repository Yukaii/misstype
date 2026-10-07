// Light / dark for the page. `data-scheme` on <html> is the scheme in effect
// (style.css and the keyboard read it); the button in the nav cycles
// auto → light → dark and remembers the choice. The head snippet in each page
// sets data-scheme before first paint so a dark visitor never sees a flash.
const KEY = "misstype-theme";
const root = document.documentElement;
const query = matchMedia("(prefers-color-scheme: dark)");
const button = document.querySelector(".theme-toggle");
const ORDER = ["auto", "light", "dark"];

const stored = () => {
  try { return localStorage.getItem(KEY); } catch { return null; }
};
let chosen = stored();
const mode = () => (ORDER.includes(chosen) ? chosen : "auto");

function apply() {
  const m = mode();
  root.dataset.scheme = m === "auto" ? (query.matches ? "dark" : "light") : m;
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
