// Where Dropbox and Google send the browser after sign-in (cloud.js). Hands
// the answer (a code, or a token in the fragment) to the editor through
// localStorage, whose `storage` event reaches the tab that opened this
// popup; after a full-page redirect the editor picks it up on load.
import { PENDING_KEY, RESULT_KEY } from "./cloud.js";

const params = new URLSearchParams(location.search);
for (const [k, v] of new URLSearchParams(location.hash.slice(1))) params.set(k, v);
try {
  localStorage.setItem(RESULT_KEY, JSON.stringify(Object.fromEntries(params)));
} catch { /* private mode: nothing to hand over */ }
// Keep the token out of history.
history.replaceState(null, "", location.pathname);
// A provider page may cut `window.opener`, so ask the sign-in record how it was opened.
let popup = Boolean(window.opener);
try { popup ||= Boolean(JSON.parse(localStorage.getItem(PENDING_KEY) || "null")?.popup); } catch { /* damaged */ }
if (popup) {
  window.close();
  document.querySelector("#msg").textContent = "已完成，可以關閉這個視窗。";
} else {
  location.replace("./");
}
