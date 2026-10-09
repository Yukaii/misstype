// Checks the editor's Wordgard -> Markdown serializer (site/editor/markdown.js)
// on documents built from JSON, so no browser is needed.
//   cd site && npm ci && node ../tests/editor_markdown_test.mjs
import assert from "node:assert/strict";
import test from "node:test";
import { GardState } from "../site/node_modules/wordgard/dist/state.js";
import { fullSchema } from "../site/node_modules/wordgard/dist/schema.js";
import { toMarkdown, wordCount } from "../site/editor/markdown.js";

const text = (param, marks) => ({ type: "Text", param, ...(marks ? { marks } : {}) });
const para = (...content) => ({ type: "Paragraph", content });
const doc = (...content) => GardState.create({ doc: { type: "Doc", content }, config: [fullSchema()] }).doc;

test("headings, paragraphs and lists", () => {
  const md = toMarkdown(doc(
    { type: "Heading", param: 2, content: [text("標題")] },
    para(text("你好")),
    { type: "BulletList", content: [
      { type: "ListItem", content: [para(text("一"))] },
      { type: "ListItem", content: [para(text("二"))] },
    ] },
    { type: "OrderedList", content: [{ type: "ListItem", content: [para(text("甲"))] }] },
  ));
  assert.equal(md, "## 標題\n\n你好\n\n- 一\n- 二\n\n1. 甲\n");
});

test("inline marks wrap runs and escape specials", () => {
  const md = toMarkdown(doc(para(
    text("a*b "),
    text("bold", { Strong: null }),
    text(" x", { Strong: null, Emphasis: null }),
  )));
  assert.equal(md, "a\\*b **bold** ***x***\n");
});

test("code blocks and quotes", () => {
  const md = toMarkdown(doc(
    { type: "Blockquote", content: [para(text("引用"))] },
    { type: "CodeBlock", content: [text("let x = 1")] },
  ));
  assert.equal(md, "> 引用\n\n```\nlet x = 1\n```\n");
});

test("word count treats each Han character as a word", () => {
  assert.deepEqual(wordCount(doc(para(text("你好 hello world")))), { chars: 2, words: 2, total: 4 });
});
