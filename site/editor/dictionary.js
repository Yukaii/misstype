// "My Dictionary": the same plain-text editor as the desktop Settings pane
// (Sources/MisstypeIME/SettingsView.swift) over the same file format
// (`text reading [weight]`, `!text reading` hides a built-in word). The wasm
// module has no files, so the text lives in localStorage and is handed to the
// decoder at start and on Save.
const KEY = "misstype-user-dictionary";

const read = () => {
  try { return localStorage.getItem(KEY) || ""; } catch { return ""; }
};
const write = (text) => {
  try { localStorage.setItem(KEY, text); } catch { /* storage full or private mode */ }
};

export function createDictionary({ getIme, toast, onClose }) {
  const dialog = document.querySelector("#dictionary");
  const area = dialog.querySelector("#dict-text");
  const note = dialog.querySelector("#dict-note");
  const problemsEl = dialog.querySelector("#dict-problems");
  const countEl = dialog.querySelector("#dict-count");
  const [importBtn, exportBtn, revertBtn, saveBtn] = ["import", "export", "revert", "save"]
    .map((name) => dialog.querySelector(`[data-dict="${name}"]`));

  let saved = "";
  let known = 0;

  const dirty = () => area.value !== saved;

  function refresh() {
    const ime = getIme();
    const result = ime ? ime.checkUserDictionary(area.value) : { added: 0, hidden: 0, problems: [] };
    countEl.textContent = `${result.added} 個詞，${result.hidden} 個隱藏`;
    const shown = result.problems.slice(0, 5).map((p) => `<li>第 ${p.line} 行：${escapeHtml(p.message)}</li>`);
    if (result.problems.length > 5) shown.push(`<li>⋯還有 ${result.problems.length - 5} 筆</li>`);
    problemsEl.innerHTML = shown.join("");
    revertBtn.disabled = saveBtn.disabled = !dirty();
  }

  function load() {
    const ime = getIme();
    // The stored text keeps the user's comments and layout, like the desktop file does.
    saved = read() || (ime ? ime.userDictionaryText() : "");
    area.value = saved;
    note.textContent = "";
    refresh();
  }

  function save() {
    const ime = getIme();
    if (!ime || !dirty()) return;
    if (!ime.setUserDictionary(area.value)) return toast("詞庫套用失敗");
    // What the decoder holds is canonical; keep the user's own layout in the box.
    write(area.value);
    known = ime.userDictionaryCount();
    saved = area.value;
    note.textContent = "";
    refresh();
    toast("已儲存詞庫");
  }

  async function importFile() {
    const input = Object.assign(document.createElement("input"), { type: "file", accept: ".txt,.tsv,text/plain" });
    input.addEventListener("change", async () => {
      const file = input.files?.[0];
      const ime = getIme();
      if (!file || !ime) return;
      let source;
      try {
        source = await file.text();
      } catch {
        note.textContent = `無法以 UTF-8 讀取 ${file.name}。`;
        return;
      }
      const merged = ime.importUserDictionary(source, area.value);
      area.value = merged.text;
      note.textContent = `匯入 ${merged.added} 個詞（${merged.duplicates} 個已存在，略過 ${merged.skipped} 行）。按「儲存」套用。`;
      refresh();
    });
    input.click();
  }

  function exportFile() {
    const url = URL.createObjectURL(new Blob([area.value], { type: "text/tab-separated-values;charset=utf-8" }));
    const a = Object.assign(document.createElement("a"), { href: url, download: "user_dictionary.tsv" });
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  area.addEventListener("input", refresh);
  saveBtn.addEventListener("click", save);
  revertBtn.addEventListener("click", load);
  importBtn.addEventListener("click", importFile);
  exportBtn.addEventListener("click", exportFile);
  dialog.querySelector("[data-close]").addEventListener("click", () => dialog.close());
  dialog.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.code === "KeyS") {
      e.preventDefault();
      save();
    }
  });
  // Don't lose edits to a stray Escape or backdrop tap.
  dialog.addEventListener("cancel", (e) => {
    if (dirty() && !confirm("放棄未儲存的詞庫變更？")) e.preventDefault();
  });
  dialog.addEventListener("pointerdown", (e) => {
    if (e.target === dialog && (!dirty() || confirm("放棄未儲存的詞庫變更？"))) dialog.close();
  });
  dialog.addEventListener("close", onClose);

  return {
    get isOpen() { return dialog.open; },
    open() {
      if (!getIme()) return toast("注音還在載入");
      load();
      dialog.showModal();
      area.focus();
    },
    /** Applies the stored dictionary once the decoder is up. */
    restore(ime) {
      const stored = read();
      if (stored) ime.setUserDictionary(stored);
      known = ime.userDictionaryCount();
    },
    /** Call after each key: a phrase filed (or removed) with Return is saved. */
    persistIfChanged(ime) {
      const count = ime.userDictionaryCount();
      if (count === known) return;
      known = count;
      write(ime.userDictionaryText());
    },
  };
}

const escapeHtml = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[c]));
