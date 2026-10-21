import { Plugin } from "prosemirror-state";
import { Decoration, DecorationSet } from "prosemirror-view";

// Zen mode dims every block but the one being written. The blocks around the
// cursor (the paragraph, and the list item, list or quote holding it) carry
// .zen-path; editor.css dims everything else, only while body.zen is set, so
// the plugin can run all the time and switching costs no redraw.
export const zenPlugin = new Plugin({
  props: {
    decorations({ doc, selection }) {
      const { $head } = selection;
      const marks = [];
      for (let d = 1; d <= $head.depth; d++) {
        marks.push(Decoration.node($head.before(d), $head.after(d), { class: "zen-path" }));
      }
      // A selected leaf block (a divider) is the current block itself.
      const node = selection.node;
      if (node?.isBlock) marks.push(Decoration.node(selection.from, selection.to, { class: "zen-path" }));
      return marks.length ? DecorationSet.create(doc, marks) : null;
    },
  },
});
