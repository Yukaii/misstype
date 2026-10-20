import { InputRule, inputRules, textblockTypeInputRule, wrappingInputRule } from "prosemirror-inputrules";
import { schema } from "./model.js";

const { heading, blockquote, code_block, bullet_list, ordered_list, horizontal_rule } = schema.nodes;
const { strong, em, code } = schema.marks;

// Typing the closing delimiter of **bold**, *italic* or `code` swaps the
// markdown for the formatted text. The typed character is not in the document
// yet, so the replaced range ends one short of the match text.
const markRule = (expr, mark) => new InputRule(expr, (state, match, start, end) => {
  const tr = state.tr.replaceWith(start, end, schema.text(match[1], [mark.create()]));
  return tr.removeStoredMark(mark);
});

// `---`, `***` or `___` alone in a paragraph turns it into a divider; the
// caret stays in the (now empty) paragraph below it.
const dividerRule = new InputRule(/^(?:---|\*\*\*|___)$/, (state, match, start, end) => {
  const $start = state.doc.resolve(start);
  const index = $start.index(-1);
  if ($start.parent.type !== schema.nodes.paragraph || !$start.node(-1).canReplaceWith(index, index, horizontal_rule)) return null;
  return state.tr.delete(start, end).insert($start.before(), horizontal_rule.create());
});

// In Chinese mode the decoder owns -, #, *, ` and digits, so these only fire
// for text typed in English mode (docs/editor.md).
export const markdownRules = inputRules({
  rules: [
    textblockTypeInputRule(/^(#{1,6})\s$/, heading, (m) => ({ level: m[1].length })),
    wrappingInputRule(/^\s*>\s$/, blockquote),
    textblockTypeInputRule(/^```$/, code_block),
    dividerRule,
    wrappingInputRule(/^\s*([-+*])\s$/, bullet_list, { tight: true }),
    wrappingInputRule(/^(\d+)\.\s$/, ordered_list, (m) => ({ order: +m[1], tight: true }), (m, node) => node.childCount + node.attrs.order === +m[1]),
    markRule(/\*\*([^*\s](?:[^*]*[^*\s])?)\*\*$/, strong),
    markRule(/(?<![*\w])\*([^*\s](?:[^*]*[^*\s])?)\*$/, em),
    markRule(/`([^`\s](?:[^`]*[^`\s])?)`$/, code),
  ],
});
