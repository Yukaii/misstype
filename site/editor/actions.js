import { chainCommands, createParagraphNear, lift, liftEmptyBlock, newlineInCode, setBlockType, splitBlock, toggleMark, wrapIn } from "prosemirror-commands";
import { liftListItem, sinkListItem, splitListItem, wrapInList } from "prosemirror-schema-list";
import { undoInputRule } from "prosemirror-inputrules";
import { schema } from "./model.js";

const { paragraph, heading, blockquote, code_block, bullet_list, ordered_list, list_item, hard_break } = schema.nodes;
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
};

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
