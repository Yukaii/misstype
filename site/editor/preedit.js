import { Plugin, PluginKey } from "prosemirror-state";
import { Decoration, DecorationSet } from "prosemirror-view";

// The decoder's pre-edit text is drawn inside the document as a widget at the
// cursor, like the landing page playground, but it is never part of the
// document: history, saving and copying only ever see finished text. Text the
// pre-edit replaces (a selection) is hidden, and comes back if it is cancelled.
export const preeditKey = new PluginKey("preedit");

const escapeHtml = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[c]));

function preeditDom(state) {
  const text = state.preedit;
  const segments = state.segments?.length ? state.segments : [[0, text.length]];
  const caret = Math.max(0, Math.min(text.length, state.caret));
  const el = document.createElement("span");
  el.className = "pg-preedit";
  el.contentEditable = "false";
  el.innerHTML = segments.map(([start, end]) => {
    const focused = state.focus && start === state.focus[0] && end === state.focus[1];
    let html = escapeHtml(text.slice(start, end));
    if (caret >= start && (caret < end || (caret === end && end === text.length))) {
      html = escapeHtml(text.slice(start, caret)) + '<span class="pg-composition-caret" aria-hidden="true"></span>'
        + escapeHtml(text.slice(caret, end));
    }
    return `<span class="pg-seg${focused ? " focused" : ""}">${html}</span>`;
  }).join("");
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
        key: JSON.stringify([value.preedit, value.segments, value.focus, value.caret]),
      })];
      if (from !== to) decorations.push(Decoration.inline(from, to, { class: "pm-replaced" }));
      return DecorationSet.create(editorState.doc, decorations);
    },
    attributes: (editorState) => (preeditKey.getState(editorState)?.preedit ? { class: "composing" } : {}),
  },
});

export const setPreedit = (tr, value) => tr.setMeta(preeditKey, { value });
