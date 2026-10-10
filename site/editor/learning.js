// "學習資料": what the decoder has learned from explicit candidate picks and
// (experimental) typing slips. Same JSON as the desktop apps' user_lexicon.json
// and channel_model.json, kept in localStorage because the wasm module has no
// files; it is handed back to the decoder at start. Switching learning on or
// off lives in Settings (settings.js); this pane is for review and cleanup.
const PHRASES_KEY = "misstype-learned";
const SLIPS_KEY = "misstype-learned-slips";

const read = (key) => {
  try { return localStorage.getItem(key) || ""; } catch { return ""; }
};
const write = (key, text) => {
  try { localStorage.setItem(key, text); } catch { /* storage full or private mode */ }
};

const escapeHtml = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[c]));

export function createLearning({ getIme, toast, onClose }) {
  const dialog = document.querySelector("#learning");
  const phrasesEl = dialog.querySelector("#learn-phrases");
  const slipsEl = dialog.querySelector("#learn-slips");
  const phraseCount = dialog.querySelector("#learn-phrase-count");
  const slipCount = dialog.querySelector("#learn-slip-count");
  const note = dialog.querySelector("#learn-note");
  const button = (name) => dialog.querySelector(`[data-learn="${name}"]`);

  let revision = 0;

  function save(ime) {
    revision = ime.learningRevision();
    write(PHRASES_KEY, ime.learnedCount() ? ime.learnedData() : "");
    write(SLIPS_KEY, ime.channelCount() ? ime.channelData() : "");
  }

  function render() {
    const ime = getIme();
    if (!ime) return;
    const phrases = ime.learnedPhrases();
    phraseCount.textContent = `${phrases.length} 筆`;
    phrasesEl.innerHTML = phrases.map((p, i) =>
      `<li><span class="learn-text">${escapeHtml(p.text)}</span>`
      + `<span class="learn-reading">${escapeHtml(p.reading)}</span>`
      + `<span class="learn-times">${p.count} 次</span>`
      + `<button class="tool" type="button" data-forget="${i}" aria-label="忘記「${escapeHtml(p.text)}」">忘記</button></li>`).join("");
    phrasesEl.hidden = phrases.length === 0;
    button("clear-phrases").disabled = button("export-phrases").disabled = phrases.length === 0;

    const slips = ime.channelPairs();
    slipCount.textContent = `${slips.length} 組`;
    slipsEl.innerHTML = slips.map((s) =>
      `<li><span class="learn-text">${escapeHtml(s.typed)} → ${escapeHtml(s.intended)}</span>`
      + `<span class="learn-times">約 ${Math.round(Math.exp(-s.cost) * 100)}%</span></li>`).join("");
    slipsEl.hidden = slips.length === 0;
    button("clear-slips").disabled = slips.length === 0;
    dialog.phrases = phrases;
  }

  function download(name, type, text) {
    const url = URL.createObjectURL(new Blob([text], { type }));
    const a = Object.assign(document.createElement("a"), { href: url, download: name });
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  phrasesEl.addEventListener("click", (e) => {
    const forget = e.target.closest("[data-forget]");
    const ime = getIme();
    if (!forget || !ime) return;
    const phrase = dialog.phrases[Number(forget.dataset.forget)];
    if (!phrase) return;
    ime.forgetLearned(phrase.reading, phrase.text);
    save(ime);
    note.textContent = `已忘記「${phrase.text}」。`;
    render();
  });

  button("export-phrases").addEventListener("click", () => {
    const ime = getIme();
    if (ime) download("user_lexicon.json", "application/json", ime.learnedData());
  });

  button("import-phrases").addEventListener("click", () => {
    const input = Object.assign(document.createElement("input"), { type: "file", accept: ".json,application/json" });
    input.addEventListener("change", async () => {
      const file = input.files?.[0];
      const ime = getIme();
      if (!file || !ime) return;
      let text = "";
      try { text = await file.text(); } catch { /* reported below */ }
      if (!text || !ime.loadLearned(text)) {
        note.textContent = `${file.name} 不是學習資料檔（user_lexicon.json）。`;
        return;
      }
      save(ime);
      note.textContent = `已載入 ${ime.learnedCount()} 筆，取代原有的學習資料。`;
      render();
    });
    input.click();
  });

  button("clear-phrases").addEventListener("click", () => {
    const ime = getIme();
    if (!ime || !confirm("清除所有學到的詞？這無法復原。")) return;
    ime.clearLearned();
    save(ime);
    note.textContent = "已清除。";
    render();
  });

  button("clear-slips").addEventListener("click", () => {
    const ime = getIme();
    if (!ime || !confirm("清除所有學到的打錯習慣？這無法復原。")) return;
    ime.clearChannel();
    save(ime);
    note.textContent = "已清除。";
    render();
  });

  dialog.querySelector("[data-close]").addEventListener("click", () => dialog.close());
  dialog.addEventListener("pointerdown", (e) => { if (e.target === dialog) dialog.close(); });
  dialog.addEventListener("close", onClose);

  return {
    get isOpen() { return dialog.open; },
    open() {
      if (!getIme()) return toast("注音還在載入");
      // Phrases may have been learned since the last time the pane was open.
      note.textContent = "";
      render();
      dialog.showModal();
    },
    /** Hands the stored learning data to the decoder once it is up. */
    restore(ime) {
      const phrases = read(PHRASES_KEY);
      if (phrases) ime.loadLearned(phrases);
      const slips = read(SLIPS_KEY);
      if (slips) ime.loadChannel(slips);
      revision = ime.learningRevision();
    },
    /** Call after each key: a pick (or slip) learned since the last call is saved. */
    persistIfChanged(ime) {
      if (ime.learningRevision() !== revision) save(ime);
    },
  };
}
