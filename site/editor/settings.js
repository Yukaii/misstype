// Options for the editor, kept in localStorage. The first six map one to one
// onto the wasm module's settings (packages/misstype-wasm README); the rest
// are presentation only.
const KEY = "misstype-editor-settings";

export const DEFAULTS = {
  pageSize: 9,
  shiftToggle: true,
  returnConfirmsSelection: true,
  autoShowCandidates: true,
  userLearning: true,
  channelLearning: false,
  candidateLayout: "vertical",
  candidateTheme: "system",
  fontSize: 18,
  wrap: "comfortable",
};

export const IME_KEYS = ["pageSize", "shiftToggle", "returnConfirmsSelection", "autoShowCandidates", "userLearning", "channelLearning"];

export function loadSettings() {
  try {
    return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(KEY) || "{}") };
  } catch {
    return { ...DEFAULTS };
  }
}

export function saveSettings(settings) {
  try { localStorage.setItem(KEY, JSON.stringify(settings)); } catch { /* private mode */ }
}
