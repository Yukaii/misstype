import { Plugin, PluginKey } from "prosemirror-state";
import { Decoration, DecorationSet } from "prosemirror-view";

// The decoder's pre-edit text is drawn inside the document as a widget at the
// cursor, like the landing page playground, but it is never part of the
// document: history, saving and copying only ever see finished text. Text the
// pre-edit replaces (a selection) is hidden, and comes back if it is cancelled.
export const preeditKey = new PluginKey("preedit");

const escapeHtml = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[c]));

const MARK_HINT = {
  add: "Enter 加入詞庫",
  remove: "Enter 從詞庫移除",
  tooShort: "至少要選 2 個字",
  tooLong: "最多 8 個字",
};

// One segment as HTML: the cursor sits at `caret`, characters inside the
// phrase marked with Shift+←/→ (UTF-16 `mark` range) get a highlight.
function segmentHtml(text, start, end, caret, mark) {
  let html = "";
  for (let i = start; i < end; i++) {
    if (i === caret) html += '<span class="pg-composition-caret" aria-hidden="true"></span>';
    const marked = mark && i >= mark.range[0] && i < mark.range[1];
    html += marked ? `<span class="pg-marked">${escapeHtml(text[i])}</span>` : escapeHtml(text[i]);
  }
  if (caret === end && end === text.length) html += '<span class="pg-composition-caret" aria-hidden="true"></span>';
  return html;
}

function preeditDom(state) {
  const text = state.preedit;
  const segments = state.segments?.length ? state.segments : [[0, text.length]];
  const caret = Math.max(0, Math.min(text.length, state.caret));
  const el = document.createElement("span");
  el.className = "pg-preedit";
  el.contentEditable = "false";
  el.innerHTML = segments.map(([start, end]) => {
    const focused = state.focus && start === state.focus[0] && end === state.focus[1];
    return `<span class="pg-seg${focused ? " focused" : ""}">${segmentHtml(text, start, end, caret, state.mark)}</span>`;
  }).join("") + (state.mark && MARK_HINT[state.mark.action]
    ? `<span class="pg-mark-hint">${MARK_HINT[state.mark.action]}</span>` : "");
  return el;
}

/** Plugin state is the decoder view (or null); update it with `setPreedit`. */
export const preeditPlugin = new Plugin({
  key: preeditKey,
  state: {
    init: () => null,
    apply: (tr, value) => {
      const meta = tr.getMeta(preeditKey);
      return meta === undefined ? value : meta.value;
    },
  },
  props: {
    decorations(editorState) {
      const value = preeditKey.getState(editorState);
      if (!value?.preedit) return null;
      const { from, to } = editorState.selection;
      const decorations = [Decoration.widget(from, () => preeditDom(value), {
        side: -1,
        ignoreSelection: true,
        key: JSON.stringify([value.preedit, value.segments, value.focus, value.caret, value.mark]),
      })];
      if (from !== to) decorations.push(Decoration.inline(from, to, { class: "pm-replaced" }));
      return DecorationSet.create(editorState.doc, decorations);
    },
    attributes: (editorState) => (preeditKey.getState(editorState)?.preedit ? { class: "composing" } : {}),
  },
});

export const setPreedit = (tr, value) => tr.setMeta(preeditKey, { value });
