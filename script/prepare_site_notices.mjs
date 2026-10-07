// Run by npm's prebuild/predev hooks, after dependencies are installed.
// License text is copied verbatim; no network or dictionary input is needed.
import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const out = resolve(root, "site/public");
const packageRoot = (name) => resolve(root, "site/node_modules", name);
const version = (name) => JSON.parse(readFileSync(resolve(packageRoot(name), "package.json"), "utf8")).version;
const escapeHTML = (text) => text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");

mkdirSync(out, { recursive: true });
for (const name of ["LICENSE", "THIRD_PARTY_NOTICES.md", "third_party"]) {
  cpSync(resolve(root, name), resolve(out, name), { recursive: true });
}
const extra = [
  ["Hairline", resolve(root, "site/hairline/LICENSE"), "third_party/Hairline/LICENSE"],
  [`browser_wasi_shim ${version("@bjorn3/browser_wasi_shim")} (MIT option)`, resolve(packageRoot("@bjorn3/browser_wasi_shim"), "LICENSE-MIT"), "third_party/browser_wasi_shim/LICENSE-MIT"],
  [`Vite ${version("vite")}`, resolve(packageRoot("vite"), "LICENSE.md"), "third_party/Vite/LICENSE.md"],
];
for (const [, source, target] of extra) {
  mkdirSync(dirname(resolve(out, target)), { recursive: true });
  cpSync(source, resolve(out, target));
}
const sections = [
  ["Misstype (MIT)", "LICENSE"],
  ["Third-party notices / 第三方聲明", "THIRD_PARTY_NOTICES.md"],
  ["McBopomofo (MIT)", "third_party/McBopomofo/LICENSE.txt"],
  ["libtabe (BSD-style)", "third_party/libtabe/COPYING"],
  ["NAER / 國家教育研究院 (CC BY 4.0)", "third_party/NAER/LICENSE.md", "https://creativecommons.org/licenses/by/4.0/"],
  ["FrequencyWords / english.tsv (CC BY-SA 4.0)", "third_party/FrequencyWords/LICENSE.md", "https://creativecommons.org/licenses/by-sa/4.0/"],
  ...extra.map(([label, , target]) => [label, target]),
];
const content = sections.map(([label, path, licenseURL]) => `
<section>
  <h2>${escapeHTML(label)}</h2>
  <p><a href="${path}">License / attribution file</a>${licenseURL ? ` · <a href="${licenseURL}">Creative Commons license</a>` : ""}</p>
  <pre>${escapeHTML(readFileSync(resolve(out, path), "utf8"))}</pre>
</section>`).join("\n");
writeFileSync(resolve(out, "licenses.html"), `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Misstype — Licenses / 授權</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 2rem auto; padding: 0 1rem; max-width: 75ch; line-height: 1.6; }
    pre { white-space: pre-wrap; overflow-wrap: anywhere; font-size: .875rem; }
    section { border-top: 1px solid #aaa; margin-top: 2rem; }
  </style>
</head>
<body>
<main>
  <p><a href="./">中文首頁</a> · <a href="en/">English home</a></p>
  <h1>Licenses / 授權與第三方聲明</h1>
  <p>Misstype's own code is MIT licensed. Third-party code and dictionaries retain their respective licenses.</p>
  <p>Misstype 自有程式碼採 MIT 授權；第三方程式碼與詞庫依各自授權。英文詞表 english.tsv 採 CC BY-SA 4.0。</p>
  ${content}
</main>
</body>
</html>
`);
console.log("Prepared website license page and notices in site/public/");
