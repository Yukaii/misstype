# Linux port (fcitx5): task plan

Status (2026-09-28): planned. The toolchain and the risky integration points
were proven by a throwaway spike (below); no port code is in the repository
yet except the dev container. Each task is sized for one agent, lands as its
own commit, and ends with commands whose output decides pass/fail.

**Goal:** Mistype runs as an fcitx5 input method on Linux with the same
behavior as macOS, built from the same `MistypeCore`, and verified headlessly
in CI against the conformance scenarios in `docs/cross-platform.md`.

**Non-goals for this plan:** IBus, Jev (remote assistance) on Linux, a
settings UI, distro packages. See the backlog (L7).

## Read first (every task)

1. `AGENTS.md`: product constraints, privacy rules, definition of done.
2. `docs/cross-platform.md`: the adapter contract (§1–§6), delivery rules,
   and conformance scenarios C1–C12. **It is normative; this plan applies it.**
3. `docs/architecture.md`, section "Platform boundary: InputSession".
4. `Sources/MistypeCore/InputSession.swift`, `KeyEvent.swift`, and
   `tests/MistypeCoreTests/InputSessionTests.swift`: the reference behavior.

## Ground rules (every task)

- **Do not change what a key sequence produces.** `InputSession`,
  `Composition`, the decoder, and their tests are off limits except where a
  task says so (L1 adds key tables only). If the contract seems wrong, stop
  and report instead of special-casing an adapter.
- **Run everything Linux through the dev container**, from the repo root:
  `script/linux/dev.sh '<command>'`. It builds `linux/Dockerfile` (Swift 6.0,
  Ubuntu 24.04, fcitx5 5.1.7 + dev headers + test harness) and runs the
  command in a fresh copy of the working tree at `/w`.
- **Keep macOS green:** `swift build` and `swift test` on the macOS host must
  still pass after every task (CI does not cover macOS outside releases).
- **Fixtures are synthetic.** Tests use `tests/fixtures/lexicon/` (created in
  L2), never the real lexicon or personal text. Never log typed text.
- **No network in tests.** Only `script/prepare_lexicon.py` downloads, and
  only the pinned sources (used by L4's build, not by tests).
- **Done means the task's "Done when" commands print exactly what is listed**,
  plus the macOS checks. Paste their output in the commit message body or the
  hand-off note.

## Verified facts (spike, 2026-09-28)

Each was run end to end in the dev container, so tasks can rely on them:

| Fact | Consequence |
|---|---|
| `swift build -c release --product <lib> -Xswiftc -static-stdlib` makes a `.so` with **no** Swift runtime dependencies; ~71 MB, ~56 MB stripped (aarch64). Beyond libc/libm/libstdc++/libgcc_s its only dynamic dependency is `libcurl.so.4` (FoundationNetworking, pulled in by `JevClient`) | Ship one self-contained `libMistypeCAPI.so`; `libcurl4` is a runtime dependency |
| SwiftPM sets no SONAME on the `.so`; CMake still records the bare `libMistypeCAPI.so` in the addon's `NEEDED` | Add `-Xlinker -soname=libMistypeCAPI.so` anyway (deterministic) |
| A C target `CMistype` (header in `include/`) imported by a Swift target lets `@_cdecl` functions take and **return C structs by value**; a C program calls them; builds on macOS too | The header is the single source of truth for the ABI (L2) |
| A C++ fcitx5 addon (`InputMethodEngineV2`, `FCITX_ADDON_FACTORY`) linking that `.so` loads in fcitx5 5.1.7 | L3 architecture |
| fcitx5's in-process harness works headlessly: `setupTestingEnvironment` + `--disable=all --enable=testim,testfrontend,mistype,testui`; typing `s u 3 c l 3` produced client preedit `你好` | L3 tests need no display or D-Bus |
| `ITestFrontend::pushCommitExpectation` **aborts the test (exit 134)** on a wrong commit | A green `ctest` is meaningful |
| `ITestFrontend::sendKeyEvent` returns whether the key was filtered (empty-composition Enter → `false`, `s` → `true`) | Pass-through (C2, C9, C10) is assertable |
| Test keys need real codes: `Key(sym, states, evdev + 8)`; `rawKey().code() - 8` is the evdev code | Keymap by scancode (L1, L3) |
| fcitx5 `Text::setCursor` counts **UTF-8 bytes** | C ABI exposes `caret_bytes` |
| fcitx5 `GlobalConfig::altTriggerKeys` defaults to `Shift_L`; in the harness a lone `Shift_L` tap (press `Key(Shift_L, {}, 50)`, release `Key(Shift_L, Shift, 50)`) switched the IC to `keyboard-us` | fcitx5 owns lone-Shift 中/英; the session's `shift_toggle` is 0 on Linux |
| fcitx5 reports modifier state **before** the event (X11 semantics) | Adapter corrects Shift's own press/release (contract §1) |
| On Docker Desktop for macOS, a file edited on the host can be read stale through the bind mount for a moment | If the container reports impossible errors (e.g. "unterminated #ifdef" in a complete file), rerun |

## Target layout

```text
Package.swift                         + CMistype (C, header-only) + MistypeCAPI (Swift, dynamic product)
Sources/CMistype/include/mistype.h    the C ABI (Appendix A, verbatim)
Sources/CMistype/module.c             comment-only translation unit (SwiftPM needs one source)
Sources/MistypeCAPI/*.swift           @_cdecl implementation over MistypeCore
Sources/MistypeCore/KeyEvent.swift    + EvdevKeyCode, USLayout (L1)
tests/MistypeCoreTests/KeyMapTests.swift
tests/fixtures/lexicon/lexicon.tsv    the 7-line conformance fixture
tests/capi/smoke.c, tests/capi/expected.txt
linux/Dockerfile                      dev/CI image (exists)
linux/fcitx5/CMakeLists.txt
linux/fcitx5/src/                     engine + per-IC state + candidate word
linux/fcitx5/data/addon/mistype.conf.in, data/inputmethod/mistype.conf
linux/fcitx5/test/testmistype.cpp     C1–C12 + Linux delivery rules, headless
script/linux/dev.sh                   run a command in the container (exists)
script/linux/test_capi.sh             L2 check
script/linux/test_fcitx5.sh           L3 check
script/linux/build.sh                 L4 release build (real lexicon)
```

## Dependency graph

```text
L1 key tables ──▶ L2 C ABI ──▶ L3 fcitx5 addon + headless tests ──▶ L4 install layout ──▶ L6 desktop acceptance (human)
                       └──────────────────────────────▶ L5 CI (after L3)
```

L1 is small; L2 and L3 are the bulk. L5 can start once L3 lands, in
parallel with L4.

---

## L1: Evdev and US-character key tables (core)

**Depends on:** nothing. **Touches:** `Sources/MistypeCore/KeyEvent.swift`,
new `tests/MistypeCoreTests/KeyMapTests.swift`.

**Spec**

- Add `public enum EvdevKeyCode` next to `MacKeyCode`, same shape:
  `public static let labels: [Int: String]` and
  `public static func key(_ code: Int) -> KeyEvent.Key`. Codes are Linux
  evdev codes (`/usr/include/linux/input-event-codes.h` in the container is
  the source of truth; X11/fcitx5 keycodes are these + 8).
  - `labels`: `KEY_1`…`KEY_0` (2–11) → `"1"`…`"0"`, `KEY_MINUS` 12 `"-"`,
    `KEY_EQUAL` 13 `"="`, `KEY_Q`…`KEY_P` (16–25), `KEY_LEFTBRACE` 26 `"["`,
    `KEY_RIGHTBRACE` 27 `"]"`, `KEY_A`…`KEY_L` (30–38), `KEY_SEMICOLON` 39
    `";"`, `KEY_APOSTROPHE` 40 `"'"`, `KEY_GRAVE` 41 `` "`" ``,
    `KEY_BACKSLASH` 43 `"\\"`, `KEY_Z`…`KEY_M` (44–50), `KEY_COMMA` 51 `","`,
    `KEY_DOT` 52 `"."`, `KEY_SLASH` 53 `"/"`.
  - `key(_:)`: 57 `.space`; 28 and 96 (`KEY_KPENTER`) `.enter`; 15 `.tab`;
    14 `.backspace`; 111 `.forwardDelete`; 1 `.escape`; 105 `.left`;
    106 `.right`; 103 `.up`; 108 `.down`; 42 `.shift(.left)`;
    54 `.shift(.right)`; 29, 97, 56, 100, 125, 126, 58 (Ctrl, Alt, Meta,
    Caps Lock) `.modifier`; anything else `.other`.
- Add `public enum USLayout` with
  `public static func key(forCharacter character: Character) -> (key: KeyEvent.Key, shifted: Bool)?`:
  a character typed on a US-ANSI layout → its physical key. Lowercase
  letters and unshifted glyphs → `shifted == false`; uppercase letters and
  the shifted glyphs `~!@#$%^&*()_+{}|:"<>?` → their key with
  `shifted == true` (`"!"` → `"1"`, `"~"` → `` "`" ``, `"_"` → `"-"`,
  `"{"` → `"["`, `"|"` → `"\\"`, `":"` → `";"`, `"\""` → `"'"`, `"<"` → `","`,
  `">"` → `"."`, `"?"` → `"/"`, `"+"` → `"="`); `" "` → `.space`; anything
  else → `nil`.
- Derive `USLayout` from the label set rather than a second hand-written
  table where practical, and doc-comment both types in the style of
  `MacKeyCode`.

**Done when**

```sh
swift test --filter KeyMapTests             # macOS host: "Executed N tests, with 0 failures"
script/linux/dev.sh 'swift test 2>&1 | grep -E "Executed .* tests" | tail -1'
# → "Executed <121+N> tests, with 0 failures (0 unexpected) ..."
```

`KeyMapTests` must at least assert:
`Set(EvdevKeyCode.labels.values) == Set(MacKeyCode.labels.values)` (47 labels);
`EvdevKeyCode.key(31) == .character("s")`, `key(4) == .character("3")`,
`key(57) == .space`, `key(96) == .enter`, `key(42) == .shift(.left)`,
`key(54) == .shift(.right)`, `key(29) == .modifier`, `key(102) == .other`
(Home); every Zhuyin and tone label (`ZhuyinKeyboard.symbols`/`tones` keys
minus space) is in `EvdevKeyCode.labels.values`;
`USLayout.key(forCharacter: "A")! == (.character("a"), true)`,
`"!"` → `("1", true)`, `"~"` → `` ("`", true) ``, `";"` → `(";", false)`,
`" "` → `(.space, false)`, `"中"` → `nil`; and for every label `l`,
`USLayout.key(forCharacter: Character(l))! == (.character(l), false)`.

---

## L2: C ABI (`CMistype` + `MistypeCAPI`)

**Depends on:** L1. **Touches:** `Package.swift`, new `Sources/CMistype/`,
`Sources/MistypeCAPI/`, `tests/fixtures/lexicon/lexicon.tsv`, `tests/capi/`,
`script/linux/test_capi.sh`.

**Spec**

- `Package.swift`: add `.target(name: "CMistype")` and
  `.target(name: "MistypeCAPI", dependencies: ["MistypeCore", "CMistype"])`
  to the **always-built** targets, and the product
  `.library(name: "MistypeCAPI", type: .dynamic, targets: ["MistypeCAPI"])`.
  Keep the macOS-only gating as is.
- `Sources/CMistype/include/mistype.h`: exactly the header in Appendix A
  (it compiles cleanly as C11 and C++17 with `-Wall -Wextra -Werror -pedantic`).
  Additive comment edits are fine; any signature change needs the user's
  approval because L3 and future adapters build on it.
- `Sources/CMistype/module.c`: a single comment line.
- `Sources/MistypeCAPI/`: `@_cdecl` implementations. Required behavior:
  - Handles are `Unmanaged` retained Swift objects passed as
    `OpaquePointer`. Every function tolerates `NULL` handles and returns
    zero values/`NULL`.
  - The engine handle owns an `InputEngine` plus a stored `SessionSettings`;
    `engine.settings` returns the stored value, and
    `mistype_engine_set_settings` replaces it (candidate keys go through
    `SelectionKeys.sanitize`). Jev stays at `JevConfig()` (off); no host is
    set, so remote calls are impossible from C.
  - `user_lexicon_path`: `NULL` → `UserLexicon.load()` with
    `userLexiconURL = UserLexicon.defaultURL`; `""` → empty lexicon, no URL
    (never touches disk); otherwise load/save at that path.
  - `mistype_session_handle` maps `mistype_key_event` → `KeyEvent` (kind →
    `KeyEvent.Key`, `MISTYPE_MOD_*` bits → `KeyEvent.Modifiers` of the same
    raw value, `timestamp < 0` → `nil`, `native_code < 0` → `nil`) and
    `KeyResult` → `mistype_key_result` (`commit` via `strdup`).
  - `mistype_session_view` converts `SessionView`; `caret_bytes` is the
    UTF-8 length of the preedit's first `caret_utf16` UTF-16 units.
  - Keymap functions return labels from static storage created once (for
    example a table of `strdup`ed C strings built on first use).
  - Strings and arrays are `malloc`ed; `mistype_view_free` frees the view
    and everything in it; both free functions accept `NULL`.
- `tests/fixtures/lexicon/lexicon.tsv`: the 7 lines from
  `docs/cross-platform.md` (tab-separated, trailing newline).
- `tests/capi/smoke.c` (C11): usage `smoke <resource_dir>` runs the
  scenario script below against a fresh engine (`user_lexicon_path = ""`)
  and prints exactly `tests/capi/expected.txt`. Usage
  `smoke <resource_dir> <keys>` types each character of `<keys>` as a
  physical key (via `mistype_key_from_character`; space → `MISTYPE_KEY_SPACE`),
  presses Enter, and prints `commit=<text>` (used by L4 with the real
  lexicon). Free everything it receives.
- `tests/capi/expected.txt`, exactly:

  ```text
  abi=1
  C1 preedit=你好 caret_bytes=6 caret_utf16=2 shows=1 count=10
  C1 commit=[你好]
  C2 enter consumed=0 commit=(null)
  C2 space consumed=1 commit=[ ]
  C4 tab selected=1 keys_active=1 shows=1 count=5
  C4 pick preedit=尼 keys_active=0
  C4 commit=[尼]
  C8 left caret_bytes=3 caret_utf16=1 first=你好 keys_active=1
  C9 ctrl-c consumed=0 commit=[你]
  C10 shift-space consumed=1 commit=[你] mode_changed=1 english=1
  C10 s consumed=0 commit=(null)
  C11 commit=[你]
  C12 pick preedit=泥 selected=3
  keymap evdev31=s evdev57=space evdev42=shift-left A=a+shift !=1+shift
  DONE
  ```

  Each `Cn` line comes from that conformance scenario in
  `docs/cross-platform.md`, run on a **fresh engine and session**. Commits
  print as `commit=[text]`, a `NULL` commit as `commit=(null)`; `shows` is
  `shows_candidates`, `count` is `candidate_count`. The keymap line prints
  the label for characters and a kind name (`space`, `shift-left`) otherwise.
  These values were computed from the current `InputSession` with the
  fixture (the 10 C1 rows include raw-Bopomofo fallbacks like `ㄋㄧˇ好`); if
  your output differs, the ABI conversion is wrong, not the expectation.
- `script/linux/test_capi.sh` (runs inside the container, from `/w`):
  1. `swift build -c release --product MistypeCAPI -Xswiftc -static-stdlib -Xlinker -soname=libMistypeCAPI.so`
     (the same flags everywhere the `.so` is built: L3, L4)
  2. `cc -std=c11 -Wall -Wextra -Werror -ISources/CMistype/include tests/capi/smoke.c -L<bin> -lMistypeCAPI -Wl,-rpath,<bin> -o build/capi/smoke`
  3. `build/capi/smoke tests/fixtures/lexicon | diff -u tests/capi/expected.txt -`
  4. Symbol parity: the sorted `mistype_*` names declared in the header
     (`grep -oE '\bmistype_[a-z_]+\(' | tr -d '('`) equal the sorted
     `nm -D --defined-only` `T mistype_*` symbols of the `.so`.
  5. `g++ -std=c++17 -fsyntax-only -x c++ Sources/CMistype/include/mistype.h`
  6. Print `CAPI OK`; `set -euo pipefail` so any failure exits non-zero.

**Done when**

```sh
script/linux/dev.sh script/linux/test_capi.sh     # last line: CAPI OK, exit 0
swift build && swift test                         # macOS host: all pass
```

Negative check (do it, then revert): change `C1 commit=你好` in
`expected.txt` to `C1 commit=錯` → `test_capi.sh` exits non-zero with a diff.

---

## L3: fcitx5 addon and headless conformance tests

**Depends on:** L2. **Touches:** new `linux/fcitx5/`,
`script/linux/test_fcitx5.sh`.

**Spec (apply `docs/cross-platform.md` §1–§6 and the delivery rules)**

- CMake project `linux/fcitx5`, `project(mistype VERSION 0.1 LANGUAGES CXX)`
  (the name sets `CMAKE_INSTALL_DOCDIR` in L4), C++17. `find_package(Fcitx5Core)`,
  `Fcitx5Utils`, and (tests) `Fcitx5ModuleTestFrontend`. Cache variable
  `MISTYPE_CAPI_DIR` (directory holding `libMistypeCAPI.so`); include path
  `../../Sources/CMistype/include`. Addon target `mistype-fcitx5`
  (`MODULE`, output `libmistype-fcitx5.so` in `${CMAKE_BINARY_DIR}/src`),
  linked to the `.so` with a build RPATH to `MISTYPE_CAPI_DIR`.
- Compile definition `MISTYPE_DATADIR` =
  `${CMAKE_INSTALL_FULL_DATADIR}/mistype`; the environment variable
  `MISTYPE_RESOURCES` overrides it (tests use the fixture).
- `data/addon/mistype.conf.in` → configured to
  `${CMAKE_BINARY_DIR}/data/addon/mistype.conf`:
  `[Addon] Name=Mistype, Category=InputMethod, Version=<project version>,
  Library=libmistype-fcitx5, Type=SharedLibrary, OnDemand=True,
  Configurable=False`. `data/inputmethod/mistype.conf`:
  `[InputMethod] Name=Mistype, Label=注, LangCode=zh_TW, Addon=mistype,
  Configurable=False`. The addon's name is the file's basename (`mistype`).
- Engine (`fcitx::InputMethodEngineV2`, registered with
  `FCITX_ADDON_FACTORY`):
  - Constructor: `mistype_engine_new(resources, NULL)`; apply
    `mistype_settings_default()` with `shift_toggle = 0`. If the engine is
    `NULL`, log with `FCITX_ERROR()` and pass every key through (never crash,
    never filter).
  - Per-input-context state via `fcitx::FactoryFor<MistypeState>`
    registered on `instance->inputContextManager()`; `MistypeState` owns one
    `mistype_session*` (freed in its destructor) and the last rendered view.
  - `keyEvent`: build a `mistype_key_event` from `event.rawKey()`:
    `evdev = code() - 8` when `code() > 8` → `mistype_key_from_evdev`; when
    that yields `MISTYPE_KEY_OTHER` (or there is no code) and the key's text
    is one character, fall back to `mistype_key_from_character` (add
    `MISTYPE_MOD_SHIFT` when `shifted`). `text` =
    `Key::keySymToUTF8(rawKey().sym())`, `NULL` when empty. Modifiers from
    `rawKey().states()`: `Shift`, `Ctrl`, `Alt`, `Super`/`Super2` → SUPER,
    `CapsLock`; then correct Shift keys: a Shift press adds
    `MISTYPE_MOD_SHIFT`, a Shift release removes it. `is_release` =
    `event.isRelease()`, `native_code` = `code()`, `timestamp` = -1.
  - Apply the result per contract §2. Filtering follows the delivery rules:
    never filter releases or `MISTYPE_KEY_MODIFIER`/`SHIFT_*` presses;
    otherwise `filterAndAccept()` iff `consumed`. `beep` is ignored.
    `mode_changed`: after rendering, set the panel's aux-up text to `英` or
    `中` (`mistype_engine_is_english`); the next render clears it.
  - Render per contract §3: if the IC has `CapabilityFlag::Preedit`, set the
    client preedit, else the panel preedit (`inputPanel().setPreedit`), as a
    `fcitx::Text` with `TextFormatFlag::Underline` and
    `setCursor(caret_bytes)`. Candidates: when `shows_candidates`, a
    `CommonCandidateList` with page size 8, one `CandidateWord` per entry
    whose `select()` calls `mistype_session_pick(index)` and re-renders, the
    global cursor on `selected` (its page current), labels =
    `selection_keys` when `keys_active` else empty labels. Otherwise clear
    the candidate list. Then `updatePreedit()` and
    `updateUserInterface(UserInterfaceComponent::InputPanel)`. Skip when the
    view equals the last rendered one.
  - `activate` → `mistype_session_reset_modifiers`. `deactivate` and `reset`
    always call `mistype_session_commit` (the session drops its composition)
    and render, but insert the text only when nobody else will: fcitx5
    already commits client-side preedit itself on focus out (verified in the
    harness: a second insert duplicates it), so `deactivate` inserts only for
    a switch of input method or when the context has no client preedit;
    `reset` never inserts.
- `test/testmistype.cpp`: the fcitx5 harness pattern (verified in the
  spike): `setupTestingEnvironment(TESTING_BINARY_DIR, {"src"},
  {TESTING_BINARY_DIR "/data", TESTING_SOURCE_DIR "/data"})`, `Instance` with
  `--disable=all --enable=testim,testfrontend,mistype,testui`,
  `registerDefaultLoader(nullptr)`, an `EventDispatcher` scheduling the test
  body; set the group to `keyboard-us` + `mistype`, create an IC via
  `ITestFrontend::createInputContext`, `focusIn()`,
  `setCapabilityFlags(CapabilityFlag::Preedit)`,
  `instance.setCurrentInputMethod(ic, "mistype", false)`. Keys are
  `Key(sym, states, evdev + 8)` with **pre-event** states (X11 semantics).
  The user lexicon is redirected to `build/fcitx5/xdg-data` (wiped per run);
  C4 runs last because committing 尼 teaches it and reorders every later
  scenario. Use `pushCommitExpectation` for every expected commit and the
  `sendKeyEvent` return value for filtered/passed assertions. Implement
  C1–C12 (C9 uses Ctrl+c; C11 = `ic->focusOut()`; C12 = `select()` on the
  list's candidate 3) plus:
  - **LR1** A key release is never filtered (`sendKeyEvent(..., true)`
    returns `false`) and changes nothing.
  - **LR2** With a composition, a bare `Control_L` press is not filtered and
    the preedit is unchanged.
  - **LR3** Without `CapabilityFlag::Preedit`, `s u 3` puts `你` in
    `inputPanel().preedit()` and the client preedit stays empty.
  - **LR4** A lone `Shift_L` tap switches the IC to `keyboard-us` (fcitx5
    `AltTriggerKeys`) and `mistype_engine_is_english` stays 0.
  Log `PASS <id>` with `FCITX_INFO()` after each; failures use
  `FCITX_ASSERT` (aborts, non-zero exit). Register with CTest.
- `script/linux/test_fcitx5.sh` (inside the container, from `/w`): build the
  `.so` as in L2, configure `linux/fcitx5` into `build/fcitx5` with
  `MISTYPE_CAPI_DIR`, build, run
  `MISTYPE_RESOURCES=$PWD/tests/fixtures/lexicon ctest --test-dir build/fcitx5 --output-on-failure`,
  print the `PASS` lines, then `FCITX5 OK`.

**Done when**

```sh
script/linux/dev.sh script/linux/test_fcitx5.sh
# → PASS C1 … PASS C12, PASS LR1 … PASS LR4 (16 lines), then
#   "100% tests passed, 0 tests failed out of 1", last line FCITX5 OK
script/linux/dev.sh script/linux/test_capi.sh      # still CAPI OK
swift build && swift test                          # macOS host: all pass
```

Negative check (do it, then revert): expect `錯` in C1 → the test aborts and
the script exits non-zero.

---

## L4: Release build and install layout

**Depends on:** L3. **Touches:** `linux/fcitx5/CMakeLists.txt` (install
rules), new `script/linux/build.sh`.

**Spec**

- `script/linux/build.sh` (inside the container): run
  `python3 script/prepare_lexicon.py` (pinned sources; reuses `.cache/`),
  build the `.so` (release, `-static-stdlib`), configure `linux/fcitx5` into
  `build/fcitx5` with `CMAKE_BUILD_TYPE=Release` and
  `CMAKE_INSTALL_PREFIX=/usr`, build, and build `tests/capi/smoke` into
  `build/capi/smoke`.
- Install rules (`GNUInstallDirs`; fcitx5 dirs from `FCITX_INSTALL_ADDONDIR`
  and `FCITX_INSTALL_PKGDATADIR`, which `Fcitx5Utils` exports):
  addon `.so` → `FCITX_INSTALL_ADDONDIR`; `libMistypeCAPI.so` →
  `${CMAKE_INSTALL_LIBDIR}/mistype`; the addon's install RPATH is that
  absolute directory; the configured addon conf → `…/fcitx5/addon/`;
  the IM conf → `…/fcitx5/inputmethod/`; `.cache/mcbopomofo/lexicon.tsv`,
  `.cache/mcbopomofo/toneless.tsv`, `Resources/local_phrases.tsv` →
  `${CMAKE_INSTALL_DATADIR}/mistype/`; `LICENSE`,
  `THIRD_PARTY_NOTICES.md` and `third_party/` → `${CMAKE_INSTALL_DOCDIR}`
  (the same license payload as the macOS bundle).

**Done when**

```sh
script/linux/dev.sh 'script/linux/build.sh >/dev/null && DESTDIR=/tmp/stage cmake --install build/fcitx5 >/dev/null && cd /tmp/stage && find . -type f | sed -E "s#/lib/[^/]+-linux-gnu/#/lib/<multiarch>/#" | sort'
```

prints exactly:

```text
./usr/lib/<multiarch>/fcitx5/libmistype-fcitx5.so
./usr/lib/<multiarch>/mistype/libMistypeCAPI.so
./usr/share/doc/mistype/LICENSE
./usr/share/doc/mistype/THIRD_PARTY_NOTICES.md
./usr/share/doc/mistype/third_party/McBopomofo/LICENSE.txt
./usr/share/doc/mistype/third_party/McBopomofo/README.md
./usr/share/doc/mistype/third_party/McBopomofo/sources.json
./usr/share/doc/mistype/third_party/NAER/LICENSE.md
./usr/share/doc/mistype/third_party/NAER/sources.json
./usr/share/doc/mistype/third_party/libtabe/COPYING
./usr/share/fcitx5/addon/mistype.conf
./usr/share/fcitx5/inputmethod/mistype.conf
./usr/share/mistype/lexicon.tsv
./usr/share/mistype/local_phrases.tsv
./usr/share/mistype/toneless.tsv
```

and

```sh
script/linux/dev.sh 'script/linux/build.sh >/dev/null && cmake --install build/fcitx5 >/dev/null && readelf -d /usr/lib/*/fcitx5/libmistype-fcitx5.so | grep -E "RUNPATH|RPATH" && ldd /usr/lib/*/fcitx5/libmistype-fcitx5.so | grep MistypeCAPI && build/capi/smoke /usr/share/mistype su3cl3'
```

prints the install `RUNPATH` (`/usr/lib/<multiarch>/mistype`), an `ldd` line
resolving `libMistypeCAPI.so` under it, and `commit=你好` (real lexicon).
Document the runtime packages (`fcitx5`, `libcurl4`, `libstdc++6`) in the
install section of `README`/this file.

---

## L5: CI

**Depends on:** L3 (and L2). **Touches:** `.github/workflows/ci.yml`.

**Spec:** keep the `core-linux` job. Add a `fcitx5-linux` job on
`ubuntu-latest` (Docker is available there) that runs
`script/linux/dev.sh script/linux/test_capi.sh` and
`script/linux/dev.sh script/linux/test_fcitx5.sh`. Tests only, no
`build.sh`: CI must not download the lexicon.

**Done when:** after the change is pushed,
`gh run list --workflow ci.yml --limit 1` shows `success`, and
`gh run view <id>` lists `✓ core-linux` and `✓ fcitx5-linux`. The local
negative checks from L2/L3 still fail as described (CI runs the same
scripts).

---

## L6: Desktop acceptance (human or VM)

**Depends on:** L4. Not automatable; the result is a filled-in table.

1. Ubuntu 24.04 (GNOME, Wayland) VM or machine. Build and install:
   `script/linux/build.sh` then `sudo cmake --install build/fcitx5` (outside
   the container, with the packages from `linux/Dockerfile` plus a Swift 6.0
   toolchain), or copy the staged tree from L4.
2. `sudo apt install fcitx5 fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5 fcitx5-config-qt`,
   `im-config -n fcitx5`, log out and back in, add **Mistype** in
   `fcitx5-configtool`.
3. Run C1–C12 from `docs/cross-platform.md` with the **real** lexicon
   (expected text can differ from the fixture; check behavior: what commits
   when, what passes through, where the caret is) in: GNOME Text Editor
   (GTK4), Firefox, Chromium or VS Code (Electron,
   `--enable-wayland-ime`), GNOME Terminal. Repeat in one X11 session.
4. Linux-specific checks: the candidate window follows the caret; a lone
   Left Shift toggles to English and back; switching the keyboard layout to
   Dvorak still types `ㄋㄧˇ` for the physical keys `s u 3` (positional
   mapping); holding Backspace repeats; Super shortcuts (for example the
   Activities overview) are unaffected; focus change mid-composition commits.
   If `fcitx5-chinese-addons` is installed, its full-width toggle may also be
   bound to Shift+Space and win over C10; record which one fires.
5. Append a results table to this file (environment × app × pass/fail +
   notes). Every failure becomes an issue or a new headless test, not a
   silent workaround.

---

## L7: Backlog (not scheduled)

- IBus adapter over the same C ABI (GNOME's default IM framework).
- Jev on Linux: host callbacks in the C ABI (`surrounding_text`,
  `perform`, `session_did_change`), settings, and the consent flow; privacy
  rules from `AGENTS.md` apply.
- fcitx5 configuration (candidate keys, fuzzy repair, tone tolerance,
  learning) mapped onto `mistype_settings`.
- Library size (~56–71 MB): `-Xlinker --gc-sections`, strip at install, or a
  Foundation-free core.
- Packaging: `.deb`, AUR, Flatpak (fcitx5 addon in a Flatpak runtime needs
  research).

## Open decisions (owner: user)

- **D1 Lone-Shift ownership on Linux.** Plan default: fcitx5
  `AltTriggerKeys` (switches to `keyboard-us`), session `shift_toggle = 0`.
  Alternative: remove `Shift_L` from `AltTriggerKeys` and let the session
  toggle its own English mode (matches macOS exactly, but needs a user-side
  fcitx5 config change).
- **D2 Editing chords.** macOS Cmd+Backspace (clear) and Option+Backspace
  (delete syllable) map literally to Super/Alt+Backspace on Linux, where
  users expect Ctrl+Backspace. The plan keeps the literal mapping; decide
  after L6 whether the core should learn a per-platform chord table.
- **D3 Distribution channel** (L7) and whether ~56 MB is acceptable for a
  prototype.

## Appendix A: `mistype.h` (ABI v1)

Checked on 2026-09-28 with `cc -std=c11 -Wall -Wextra -Werror -pedantic`
and `g++ -std=c++17 -Wall -Wextra -Werror` in the dev container.

```c
/* mistype.h: C ABI over MistypeCore's InputSession (docs/cross-platform.md).
 *
 * Threading: all calls for one engine and its sessions on one thread.
 * Memory: every char* and mistype_view* returned is owned by the caller and
 * must be released with mistype_string_free / mistype_view_free. Labels
 * returned by the keymap functions are static (never free them).
 */
#ifndef MISTYPE_H
#define MISTYPE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MISTYPE_ABI_VERSION 1
int32_t mistype_abi_version(void);

typedef struct mistype_engine mistype_engine;
typedef struct mistype_session mistype_session;

typedef enum mistype_key_kind {
    MISTYPE_KEY_CHARACTER = 0, /* label = US-ANSI unshifted label: "a", "1", ";", "`" */
    MISTYPE_KEY_SPACE = 1,
    MISTYPE_KEY_ENTER = 2,
    MISTYPE_KEY_TAB = 3,
    MISTYPE_KEY_BACKSPACE = 4,
    MISTYPE_KEY_FORWARD_DELETE = 5,
    MISTYPE_KEY_ESCAPE = 6,
    MISTYPE_KEY_LEFT = 7,
    MISTYPE_KEY_RIGHT = 8,
    MISTYPE_KEY_UP = 9,
    MISTYPE_KEY_DOWN = 10,
    MISTYPE_KEY_SHIFT_LEFT = 11,
    MISTYPE_KEY_SHIFT_RIGHT = 12,
    MISTYPE_KEY_MODIFIER = 13, /* Ctrl, Alt, Super, Caps Lock, Fn alone */
    MISTYPE_KEY_OTHER = 14
} mistype_key_kind;

/* Bit values equal KeyEvent.Modifiers raw values. */
enum {
    MISTYPE_MOD_SHIFT = 1 << 0,
    MISTYPE_MOD_CONTROL = 1 << 1,
    MISTYPE_MOD_ALT = 1 << 2,       /* KeyEvent.Modifiers.option */
    MISTYPE_MOD_SUPER = 1 << 3,     /* KeyEvent.Modifiers.command */
    MISTYPE_MOD_CAPS_LOCK = 1 << 4
};

typedef struct mistype_key_event {
    mistype_key_kind kind;
    const char *label;    /* MISTYPE_KEY_CHARACTER only, else NULL */
    const char *text;     /* UTF-8 the key types in the user's layout, or NULL */
    uint32_t modifiers;   /* MISTYPE_MOD_* state AFTER this event */
    int32_t is_release;   /* 1 = key-up or modifier-only transition */
    int32_t native_code;  /* diagnostics only; -1 = unknown */
    double timestamp;     /* seconds, monotonic; < 0 = now */
} mistype_key_event;

typedef struct mistype_key_result {
    int32_t consumed;     /* 0 = the application gets the key, after commit */
    char *commit;         /* UTF-8 to insert now, or NULL (mistype_string_free) */
    int32_t beep;
    int32_t mode_changed; /* 中/英 flipped: see mistype_engine_is_english */
} mistype_key_result;

typedef struct mistype_view {
    char *preedit;              /* UTF-8, "" when idle */
    int32_t caret_bytes;        /* caret as a UTF-8 byte offset into preedit */
    int32_t caret_utf16;        /* same caret in UTF-16 units (SessionView.caret) */
    char **candidates;          /* full list, candidate_count entries */
    int32_t candidate_count;
    int32_t selected;           /* index into candidates */
    char **selection_keys;      /* labels for the visible rows */
    int32_t selection_key_count;
    int32_t keys_active;        /* selection keys pick (else they type Zhuyin) */
    int32_t shows_candidates;
} mistype_view;

typedef struct mistype_settings {
    int32_t fuzzy_repair;       /* default 1 */
    int32_t tone_tolerance;     /* default 1 */
    int32_t user_learning;      /* default 1 */
    int32_t shift_toggle;       /* default 1; fcitx5 sets 0 (AltTriggerKeys owns Shift_L) */
    const char *candidate_keys; /* NULL = "asdfghjkl;"; sanitized like SelectionKeys.sanitize */
} mistype_settings;

mistype_settings mistype_settings_default(void);

/* resource_dir holds lexicon.tsv (required), local_phrases.tsv, toneless.tsv.
 * user_lexicon_path: NULL = UserLexicon.defaultURL, "" = memory only.
 * Returns NULL when lexicon.tsv is missing or unreadable. */
mistype_engine *mistype_engine_new(const char *resource_dir, const char *user_lexicon_path);
/* Releases the caller's handle; live sessions keep the engine alive. */
void mistype_engine_free(mistype_engine *engine);
void mistype_engine_set_settings(mistype_engine *engine, const mistype_settings *settings);
int32_t mistype_engine_is_english(const mistype_engine *engine);

mistype_session *mistype_session_new(mistype_engine *engine);
void mistype_session_free(mistype_session *session);
mistype_key_result mistype_session_handle(mistype_session *session, const mistype_key_event *event);
char *mistype_session_commit(mistype_session *session); /* NULL = nothing to insert */
void mistype_session_pick(mistype_session *session, int32_t index);
void mistype_session_reset_modifiers(mistype_session *session);
char *mistype_session_raw_phonetic(mistype_session *session);
mistype_view *mistype_session_view(mistype_session *session);

/* Keymap (tables live in MistypeCore). label receives a static string for
 * MISTYPE_KEY_CHARACTER, else NULL. */
mistype_key_kind mistype_key_from_evdev(int32_t evdev_code, const char **label);
/* Fallback without a scancode: one UTF-8 character typed on a US layout.
 * *shifted = 1 when the glyph needs Shift ("A", "!"). Unknown: MISTYPE_KEY_OTHER. */
mistype_key_kind mistype_key_from_character(const char *utf8, const char **label, int32_t *shifted);

void mistype_view_free(mistype_view *view);
void mistype_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif /* MISTYPE_H */
```
