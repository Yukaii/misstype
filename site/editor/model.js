import { defaultMarkdownParser, defaultMarkdownSerializer, MarkdownSerializer, schema } from "prosemirror-markdown";
import { Fragment } from "prosemirror-model";

// The editor's document model is prosemirror-markdown's schema: everything in
// it round-trips through CommonMark, so the saved note, the copied text and
// the downloaded file are all the same Markdown.
export { schema };

// CommonMark collapses runs of blank lines, so an empty paragraph (the user
// pressed Enter twice) would vanish on reload. It is written as a lone
// `&nbsp;` paragraph, which other Markdown readers draw as a blank line, and
// read back as an empty paragraph.
const NBSP = "\u00a0";
const serializer = new MarkdownSerializer({
  ...defaultMarkdownSerializer.nodes,
  paragraph(state, node) {
    if (node.content.size === 0) state.write("&nbsp;");
    else state.renderInline(node);
    state.closeBlock(node);
  },
}, defaultMarkdownSerializer.marks);

const isNbspParagraph = (node) =>
  node.type === schema.nodes.paragraph && node.childCount === 1 && node.firstChild.isText && node.firstChild.text === NBSP;

const emptyNbspParagraphs = (node) => {
  if (isNbspParagraph(node)) return node.copy(Fragment.empty);
  if (node.isLeaf) return node;
  const children = [];
  node.forEach((child) => children.push(emptyNbspParagraphs(child)));
  return node.copy(Fragment.fromArray(children));
};

export const parseMarkdown = (text) => {
  const doc = defaultMarkdownParser.parse(text);
  return doc ? emptyNbspParagraphs(doc) : schema.topNodeType.createAndFill();
};

export const toMarkdown = (doc) => {
  // A note with nothing in it is stored as "", not as a lone &nbsp;.
  const blank = doc.childCount === 1 && doc.firstChild.type === schema.nodes.paragraph && doc.firstChild.content.size === 0;
  return blank ? "" : serializer.serialize(doc);
};

const HAN = /[㐀-鿿㄀-ㄯ]/g;

/** Han characters and Latin words, so a Chinese note and an English one both count sensibly. */
export function wordCount(doc) {
  const text = doc.textBetween(0, doc.content.size, "\n");
  const chars = (text.match(HAN) || []).length;
  const words = (text.replace(HAN, " ").match(/[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu) || []).length;
  return { chars, words, total: chars + words };
}
