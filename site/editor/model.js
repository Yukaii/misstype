import { defaultMarkdownParser, defaultMarkdownSerializer, schema } from "prosemirror-markdown";

// The editor's document model is prosemirror-markdown's schema: everything in
// it round-trips through CommonMark, so the saved note, the copied text and
// the downloaded file are all the same Markdown.
export { schema };

export const parseMarkdown = (text) => defaultMarkdownParser.parse(text) ?? schema.topNodeType.createAndFill();
export const toMarkdown = (doc) => defaultMarkdownSerializer.serialize(doc);

const HAN = /[㐀-鿿㄀-ㄯ]/g;

/** Han characters and Latin words, so a Chinese note and an English one both count sensibly. */
export function wordCount(doc) {
  const text = doc.textBetween(0, doc.content.size, "\n");
  const chars = (text.match(HAN) || []).length;
  const words = (text.replace(HAN, " ").match(/[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu) || []).length;
  return { chars, words, total: chars + words };
}
