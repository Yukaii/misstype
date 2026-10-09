# misstype-wasm

Browser bindings for the Misstype Zhuyin WebAssembly engine. The package keeps
the decoder and its raw-session semantics in Zig while letting a site or app
choose its own editor and candidate UI.

The package has not yet been published to npm. From a repository checkout,
run `npm pack` in `packages/misstype-wasm`, then install the resulting tarball
in your application with `npm install /path/to/misstype-wasm-0.1.0.tgz`.

Build or download `misstype.wasm`, `lexicon.tsv`, and optionally
`toneless.tsv`/`english.tsv`, then load them by URL:

```js
import MisstypeWasm from "misstype-wasm";

const ime = await MisstypeWasm.load({
  wasmUrl: "/assets/misstype.wasm",
  lexiconUrl: "/assets/lexicon.tsv",
  tonelessUrl: "/assets/toneless.tsv",
  englishUrl: "/assets/english.tsv",
});

ime.key("KeyS", "s");
ime.key("KeyU", "u");
ime.key("Digit3", "3");
ime.key("KeyC", "c");
ime.key("KeyL", "l");
ime.key("Digit3", "3");
console.log(ime.state().preedit); // 你好
ime.key("Enter", "\r");
ime.key("Enter", "\r");
console.log(ime.takeCommitted()); // 你好
```

`key()` accepts the browser `KeyboardEvent.code`, text, modifier bitmask, and
press/release phase. `state()` returns the JSON view used by the site's demo;
`pick()`, `commit()`, `reset()`, and the English/settings methods are available
for custom UI integration. The package does not send input to a server.

Modifier bits are Shift=1, Control=2, Alt=4, Meta=8, CapsLock=16; phase is
0 for keydown and 1 for keyup. Settings supported by the current WASM module
are `autoShowCandidates`, `returnConfirmsSelection`, `shiftToggle` (booleans)
and `pageSize` (4–10). Loading an English lexicon does not enable automatic
mixed-English recognition in the current WASM API.

User dictionary (the desktop IMEs' `user_dictionary.tsv`, vChewing user data):
`userDictionaryText()`, `userDictionaryCount()`, `setUserDictionary(text)`,
`checkUserDictionary(text)` and `importUserDictionary(source, text)`. The module
keeps no files: save `userDictionaryText()` whenever `userDictionaryCount()`
changes (a phrase filed with Shift+←/→ and Return) and call
`setUserDictionary` with it at start.

To validate from the repository root:

```sh
zig=$(script/zig/bootstrap.sh)
(cd core-zig && "$zig" build wasm)
(cd packages/misstype-wasm && npm ci && npm test && npm pack --dry-run)
```

The smoke test checks the hypothesis that the JS wrapper preserves the Zig
session's settings, offline conversion, commit delivery, and English
pass-through. Assets must be hosted by your application; the tarball contains
only the wrapper, package metadata, usage documentation, and MIT license.
