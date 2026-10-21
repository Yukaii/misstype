import { chainCommands, createParagraphNear, lift, liftEmptyBlock, newlineInCode, setBlockType, splitBlock, toggleMark, wrapIn } from "prosemirror-commands";
import { liftListItem, sinkListItem, splitListItem, wrapInList } from "prosemirror-schema-list";
import { undoInputRule } from "prosemirror-inputrules";
import { Selection, TextSelection } from "prosemirror-state";
import { schema } from "./model.js";

const { paragraph, heading, blockquote, code_block, bullet_list, ordered_list, list_item, hard_break, horizontal_rule } = schema.nodes;
const { strong, em, code } = schema.marks;

const inside = (state, type, attrs) => {
  const { $from } = state.selection;
  for (let d = $from.depth; d > 0; d--) {
    const node = $from.node(d);
    if (node.type === type && (!attrs || Object.entries(attrs).every(([k, v]) => node.attrs[k] === v))) return true;
  }
  return false;
};

const toggleBlockType = (type, attrs) => (state, dispatch) =>
  (state.selection.$from.parent.hasMarkup(type, attrs) ? setBlockType(paragraph) : setBlockType(type, attrs))(state, dispatch);

const toggleWrap = (type, wrapper) => (state, dispatch) =>
  inside(state, type) ? lift(state, dispatch) : wrapper(state, dispatch);

const toggleList = (type) => (state, dispatch) => {
  if (inside(state, type)) return liftListItem(list_item)(state, dispatch);
  return wrapInList(type, { tight: true })(state, dispatch);
};

/** Every editor action by id: toolbar buttons, palette entries and key bindings share these. */
export const actions = {
  bold: { run: toggleMark(strong), active: (s) => markActive(s, strong) },
  italic: { run: toggleMark(em), active: (s) => markActive(s, em) },
  code: { run: toggleMark(code), active: (s) => markActive(s, code) },
  h1: { run: toggleBlockType(heading, { level: 1 }), active: (s) => s.selection.$from.parent.hasMarkup(heading, { level: 1 }) },
  h2: { run: toggleBlockType(heading, { level: 2 }), active: (s) => s.selection.$from.parent.hasMarkup(heading, { level: 2 }) },
  h3: { run: toggleBlockType(heading, { level: 3 }), active: (s) => s.selection.$from.parent.hasMarkup(heading, { level: 3 }) },
  paragraph: { run: setBlockType(paragraph), active: (s) => s.selection.$from.parent.hasMarkup(paragraph) },
  bulletList: { run: toggleList(bullet_list), active: (s) => inside(s, bullet_list) },
  orderedList: { run: toggleList(ordered_list), active: (s) => inside(s, ordered_list) },
  quote: { run: toggleWrap(blockquote, wrapIn(blockquote)), active: (s) => inside(s, blockquote) },
  codeBlock: { run: toggleBlockType(code_block), active: (s) => s.selection.$from.parent.type === code_block },
  divider: { run: insertDivider },
};

/** A divider after the current block, with the caret in a fresh paragraph below it. */
function insertDivider(state, dispatch) {
  const { $to } = state.selection;
  const at = $to.depth > 0 ? $to.after(1) : state.doc.content.size;
  if (dispatch) {
    const tr = state.tr.insert(at, [horizontal_rule.create(), paragraph.create()]);
    dispatch(tr.setSelection(TextSelection.create(tr.doc, at + 2)).scrollIntoView());
  }
  return true;
}

function markActive(state, mark) {
  const { from, $from, to, empty } = state.selection;
  return empty ? !!mark.isInSet(state.storedMarks || $from.marks()) : state.doc.rangeHasMark(from, to, mark);
}

const hardBreak = (state, dispatch) => {
  dispatch?.(state.tr.replaceSelectionWith(hard_break.create()).scrollIntoView());
  return true;
};

export const editingKeys = {
  Enter: chainCommands(newlineInCode, splitListItem(list_item), createParagraphNear, liftEmptyBlock, splitBlock),
  "Shift-Enter": hardBreak,
  Tab: sinkListItem(list_item),
  "Shift-Tab": liftListItem(list_item),
  Backspace: undoInputRule,
  "Mod-b": actions.bold.run,
  "Mod-i": actions.italic.run,
  "Mod-`": actions.code.run,
};

// iOS Safari with a hardware keyboard (seen on iPhone) does not move the caret
// for plain ←/→ in this editor, while ↑/↓ work; the decoder passes the keys
// on and ProseMirror leaves plain text to the browser. So on iOS the editor
// moves it: one character, or into the next / previous textblock at an edge;
// Shift extends the selection. ⌥ / ⌘ moves (word, line) stay native.
export const moveHorizontally = (dir, extend) => (state, dispatch) => {
  const { selection, doc } = state;
  let pos;
  if (!extend && !selection.empty) pos = dir < 0 ? selection.from : selection.to;
  else {
    const { $head } = selection;
    const block = $head.parent;
    if (!block.isTextblock) return false;
    const offset = $head.parentOffset;
    if (dir < 0 ? offset > 0 : offset < block.content.size) {
      // One code point (a surrogate pair is two positions); a leaf (break, image) counts as one.
      const around = dir < 0
        ? block.textBetween(Math.max(0, offset - 2), offset, "", "\ufffc")
        : block.textBetween(offset, Math.min(block.content.size, offset + 2), "", "\ufffc");
      const step = (dir < 0 ? Array.from(around).pop() : Array.from(around)[0])?.length || 1;
      pos = $head.pos + dir * step;
    } else {
      const next = Selection.findFrom(doc.resolve(dir < 0 ? $head.before() : $head.after()), dir, true);
      if (!next) return true; // start or end of the note: nothing to do, but nothing for the browser either
      pos = next.head;
    }
  }
  const sel = extend ? TextSelection.create(doc, selection.anchor, pos) : TextSelection.create(doc, pos);
  dispatch?.(state.tr.setSelection(sel).scrollIntoView());
  return true;
};

export const isIOS = /iPhone|iPad|iPod/.test(navigator.userAgent)
  || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);

export const horizontalKeys = isIOS ? {
  ArrowLeft: moveHorizontally(-1, false),
  ArrowRight: moveHorizontally(1, false),
  "Shift-ArrowLeft": moveHorizontally(-1, true),
  "Shift-ArrowRight": moveHorizontally(1, true),
} : {};
