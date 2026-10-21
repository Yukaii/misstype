// Checks the editor's own ←/→ (site/editor/actions.js moveHorizontally, used
// on iOS where Safari does not move the caret for them): one code point per
// press, across block edges, Shift extends.
//   cd site && npm ci && node ../tests/editor_arrows_test.mjs
import assert from "node:assert/strict";
import test from "node:test";
import { EditorState, TextSelection } from "../site/node_modules/prosemirror-state/dist/index.js";
import { moveHorizontally } from "../site/editor/actions.js";
import { parseMarkdown } from "../site/editor/model.js";

const at = (md, pos) => {
  const state = EditorState.create({ doc: parseMarkdown(md) });
  return state.apply(state.tr.setSelection(TextSelection.create(state.doc, pos)));
};
const press = (state, dir, extend = false) => {
  let next = state;
  assert.equal(moveHorizontally(dir, extend)(state, (tr) => { next = state.apply(tr); }), true);
  return next;
};

test("one character per press inside a paragraph", () => {
  // doc: <p>你好</p>, text starts at 1
  let s = at("你好", 3);
  s = press(s, -1); assert.equal(s.selection.head, 2);
  s = press(s, -1); assert.equal(s.selection.head, 1);
  s = press(s, 1); assert.equal(s.selection.head, 2);
});

test("an emoji is one step, not two", () => {
  let s = at("a😀b", 4); // after the emoji
  s = press(s, -1); assert.equal(s.selection.head, 2);
  s = press(s, 1); assert.equal(s.selection.head, 4);
});

test("a hard break is one step", () => {
  let s = at("a  \nb", 2); // after "a", before the break
  s = press(s, 1); assert.equal(s.selection.head, 3);
});

test("edges move into the neighbouring block, including list items", () => {
  // <p>ab</p><ul><li><p>cd</p></li></ul>: p 0..4, text 1..3; li text starts at 7
  let s = at("ab\n\n* cd", 3);
  s = press(s, 1); assert.equal(s.selection.head, 7);
  s = press(s, -1); assert.equal(s.selection.head, 3);
  // The note's very start: handled, stays put.
  s = press(at("ab", 1), -1); assert.equal(s.selection.head, 1);
});

test("Shift extends, a plain press collapses to the side", () => {
  let s = at("你好嗎", 1);
  s = press(s, 1, true); s = press(s, 1, true);
  assert.deepEqual([s.selection.anchor, s.selection.head], [1, 3]);
  s = press(s, -1, true);
  assert.deepEqual([s.selection.anchor, s.selection.head], [1, 2]);
  s = press(press(s, 1, true), 1); // plain → after a selection lands at its end
  assert.ok(s.selection.empty); assert.equal(s.selection.head, 3);
});
