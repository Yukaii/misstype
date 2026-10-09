import { InputRule } from "wordgard/editor";
import { Leaf } from "wordgard/doc";
import { history } from "wordgard/history";
import { Code, Emphasis, Strikethrough, Strong } from "wordgard/types";

// Typing the closing delimiter of **bold**, *italic*, ~~strike~~ or `code`
// replaces the markdown with the formatted text. Typed in English mode; in
// Chinese mode these keys belong to the Zhuyin decoder.
const rule = (expr, mark) => InputRule.define({
  expr,
  // Returns a transaction spec; the isolated history event lets one undo
  // turn the formatting back into the typed markdown.
  apply(state, match) {
    const [whole, inner] = [match[0], match[1]];
    return {
      changes: { from: whole.from.pos, to: whole.to.pos, insert: [Leaf.text(inner.text, [mark])] },
      // Typing on must not continue the new style.
      selection: {
        anchor: whole.from.pos + inner.text.length,
        marks: state.sel.activeMarks.filter((m) => m.type !== mark.type),
      },
      annotations: history.isolate.of(true),
    };
  },
});

export const inlineRules = [
  rule(/\*\*([^*\s](?:[^*]*[^*\s])?)\*\*$/, Strong),
  rule(/(?<![*\w])\*([^*\s](?:[^*]*[^*\s])?)\*$/, Emphasis),
  rule(/~~([^~\s](?:[^~]*[^~\s])?)~~$/, Strikethrough),
  rule(/`([^`\s](?:[^`]*[^`\s])?)`$/, Code),
].map((r) => r.extension);
