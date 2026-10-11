// Checks the editor's Markdown model (site/editor/model.js): notes survive a
// parse -> serialize round trip, and the word count handles Han and Latin text.
//   cd site && npm ci && node ../tests/editor_markdown_test.mjs
import assert from "node:assert/strict";
import test from "node:test";
import { parseMarkdown, toMarkdown, wordCount } from "../site/editor/model.js";

const roundTrip = (md) => toMarkdown(parseMarkdown(md));

test("headings, paragraphs and lists round-trip", () => {
  const md = "## 標題\n\n你好\n\n* 一\n* 二\n\n1. 甲\n2. 乙";
  assert.equal(roundTrip(md), md);
  assert.equal(roundTrip("- 一\n- 二"), "* 一\n* 二");
});

test("inline marks, links and escapes", () => {
  const md = "a\\*b **bold** *it* `code` [site](https://example.com)";
  assert.equal(roundTrip(md), md);
});

test("quotes and code blocks", () => {
  const md = "> 引用\n\n```\nlet x = 1\n```";
  assert.equal(roundTrip(md), md);
});

test("an empty note parses to one empty paragraph", () => {
  const doc = parseMarkdown("");
  assert.equal(doc.childCount, 1);
  assert.equal(toMarkdown(doc), "");
});

test("empty paragraphs survive a round trip", () => {
  const doc = parseMarkdown("a\n\n&nbsp;\n\n&nbsp;\n\nb");
  assert.deepEqual(doc.content.content.map((n) => n.content.size), [1, 0, 0, 1]);
  assert.equal(toMarkdown(doc), "a\n\n&nbsp;\n\n&nbsp;\n\nb");
  assert.equal(toMarkdown(parseMarkdown(toMarkdown(doc))), toMarkdown(doc));
});

test("word count treats each Han character as a word", () => {
  assert.deepEqual(wordCount(parseMarkdown("你好 hello world")), { chars: 2, words: 2, total: 4 });
});
