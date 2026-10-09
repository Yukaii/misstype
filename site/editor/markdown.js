import {
  Blockquote, BulletList, Code, CodeBlock, CodeBlockLanguage, Emphasis, Heading,
  HorizontalRule, Image, ImageAlt, LineBreak, Link, ListItem, InlineListItem,
  OrderedList, Strikethrough, Strong,
} from "wordgard/types";

// Wordgard documents are semantic trees; this walks one and writes
// CommonMark. Only what the editor's schema can produce is handled, and
// anything unknown degrades to its plain text.

// Singleton marks and tags carry their type; parameterised ones are the type.
const typeOf = (x) => x.type ?? x;
const isMark = (m, x) => m.type === typeOf(x);
const isNode = (n, x) => (n.tag ?? n).is(typeOf(x));

// Outermost first. A mark stays open across neighbouring leaves that share it,
// so "**a *b***" is not written as "**a****b**".
const INLINE_ORDER = [Link, Strong, Emphasis, Strikethrough, Code];

const escapeText = (text) => text.replace(/([\\`*_[\]~])/g, "\\$1");

function wrappers(type, value) {
  if (type === typeOf(Link)) return [`[`, `](${value ?? ""})`];
  if (type === typeOf(Strong)) return ["**", "**"];
  if (type === typeOf(Emphasis)) return ["*", "*"];
  if (type === typeOf(Strikethrough)) return ["~~", "~~"];
  return ["`", "`"];
}

function marksOf(node) {
  return INLINE_ORDER.flatMap((type) => {
    const mark = node.marks.find((m) => isMark(m, type));
    return mark ? [{ type: mark.type, value: mark.value }] : [];
  });
}

// CommonMark only treats a delimiter as emphasis when it hugs non-space text,
// so whitespace at the edge of a marked run is written outside the marks.
function segments(plot) {
  const out = [];
  for (const node of plot.content) {
    const marks = marksOf(node);
    if (!node.isText || !marks.length) {
      out.push({ node, marks });
      continue;
    }
    const [, lead, core, trail] = /^(\s*)([\s\S]*?)(\s*)$/.exec(node.param);
    if (lead) out.push({ text: lead, marks: [] });
    if (core) out.push({ text: core, marks });
    if (trail) out.push({ text: trail, marks: [] });
  }
  return out;
}

function inline(plot) {
  let out = "";
  const open = [];
  for (const { node, text, marks: want } of segments(plot)) {
    let keep = 0;
    while (keep < open.length && keep < want.length && open[keep].type === want[keep].type
      && open[keep].value === want[keep].value) keep++;
    while (open.length > keep) {
      const m = open.pop();
      out += wrappers(m.type, m.value)[1];
    }
    for (const m of want.slice(keep)) {
      out += wrappers(m.type, m.value)[0];
      open.push(m);
    }
    const inCode = open.some((m) => m.type === typeOf(Code));
    if (text !== undefined) out += inCode ? text : escapeText(text);
    else if (node.isText) out += inCode ? node.param : escapeText(node.param);
    else if (isNode(node, LineBreak)) out += "  \n";
    else if (isNode(node, Image)) {
      const alt = node.marks.find((m) => isMark(m, ImageAlt))?.value ?? "";
      out += `![${alt}](${node.param})`;
    }
  }
  while (open.length) {
    const m = open.pop();
    out += wrappers(m.type, m.value)[1];
  }
  return out;
}

const indent = (text, first, rest) =>
  text.split("\n").map((line, i) => (i === 0 ? first : line ? rest : "") + line).join("\n");

function listItem(item, marker) {
  const body = item.inlineContent ? inline(item) : blocks(item.content, "\n");
  return indent(body, marker, " ".repeat(marker.length));
}

function block(node) {
  if (isNode(node, Heading)) return `${"#".repeat(node.tag.param)} ${inline(node)}`;
  if (isNode(node, CodeBlock)) {
    const lang = node.marks.find((m) => isMark(m, CodeBlockLanguage))?.value ?? "";
    const text = node.textContent();
    const fence = "`".repeat(Math.max(3, ...[...text.matchAll(/`+/g)].map((m) => m[0].length + 1)));
    return `${fence}${lang}\n${text}\n${fence}`;
  }
  if (isNode(node, Blockquote)) return indent(blocks(node.content), "> ", "> ").replace(/^(>) $/gm, "$1");
  if (isNode(node, HorizontalRule)) return "---";
  if (isNode(node, BulletList)) return node.content.map((item) => listItem(item, "- ")).join("\n");
  if (isNode(node, OrderedList)) {
    const start = node.tag.param ?? 1;
    return node.content.map((item, i) => listItem(item, `${start + i}. `)).join("\n");
  }
  if (isNode(node, ListItem) || isNode(node, InlineListItem)) return listItem(node, "- ");
  if (node.inlineContent) return inline(node);
  return blocks(node.content);
}

function blocks(content, sep = "\n\n") {
  return content.filter((n) => n.isPlot || isNode(n, HorizontalRule)).map(block).join(sep);
}

export function toMarkdown(doc) {
  return blocks(doc.content).replace(/\n{3,}/g, "\n\n").trim() + "\n";
}

export function wordCount(doc) {
  const text = doc.textContent({ blockSeparator: "\n" });
  const cjk = (text.match(/[㐀-鿿㄀-ㄯ]/g) || []).length;
  const words = (text.replace(/[㐀-鿿㄀-ㄯ]/g, " ").match(/[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu) || []).length;
  return { chars: cjk, words, total: cjk + words };
}
