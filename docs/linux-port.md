# Linux port (fcitx5): task plan

Current build (2026-10-09): Linux uses the Zig core and Zig `misstypectl`; the
Swift reference was retired the same day (`docs/zig-port.md`). The Swift
implementation notes below are historical, but still describe the adapter
contract; commands that mention `swift test`, `MISSTYPE_CORE=swift` or
`Sources/MisstypeCore` refer to the retired implementation (last present at
commit `c89b857`). Run `script/linux/dev.sh 'script/linux/test_all.sh'` for
all Linux layers. `test_desktop.sh` runs only inside a disposable test
container and checks an installed addon through the production GTK frontend.


Status (2026-10-02): the user dictionary (conformance C13: Shift+arrow phrase
marking, Return files it) is wired through the C ABI and drawn by the fcitx5
addon; verified in Docker (aarch64): Swift tests, CAPI OK, fcitx5 17/17.
Earlier (2026-10-01): L1–L5 landed (key tables, C ABI, fcitx5 addon + headless
tests, install layout, CI `core-linux` + `fcitx5-linux`). The Linux layers
were additionally verified **bare-metal** (no Docker) on Ubuntu 24.04 x86_64:
`script/linux/test_all.sh` → 140/140 Swift tests, CAPI OK, fcitx5 16/16
scenarios; L4 `build.sh` + staged install matches the spec file-for-file,
RUNPATH/ldd resolve, smoke types `你好` on the real lexicon. L6 (desktop
acceptance) still needs a human or a VM with a display.

**Goal:** Misstype runs as an fcitx5 input method on Linux with the same
behavior as macOS, built from the same `MisstypeCore`, and verified headlessly
in CI against the conformance scenarios in `docs/cross-platform.md`.

**Non-goals for this plan:** IBus (built separately, see `docs/ibus-port.md`), a
settings UI, distro packages. See the backlog (L7). (Jev, remote assistance, was removed from the product on
2026-10-09.)

## Read first (every task)

1. `AGENTS.md`: product constraints, privacy rules, definition of done.
2. `docs/cross-platform.md`: the adapter contract (§1–§6), delivery rules,
   and conformance scenarios C1–C15. **It is normative; this plan applies it.**
3. `docs/architecture.md`, section "Platform boundary: InputSession".
4. `Sources/MisstypeCore/InputSession.swift`, `KeyEvent.swift`, and
   `tests/MisstypeCoreTests/InputSessionTests.swift`: the reference behavior.

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

## Bare-metal (no Docker)

For Arch Linux / Omarchy, use the pacman-managed package recipe and desktop
setup instructions in [docs/arch-linux.md](arch-linux.md). The Ubuntu
bootstrap script below is not intended for Arch.

The container remains the canonical path, but the Linux layers also run
directly on an Ubuntu 24.04 host (verified 2026-10-01):

```sh
script/linux/bootstrap.sh   # pinned Zig + native deps (idempotent)
script/linux/test_all.sh    # Zig tests + C ABI + fcitx5
```

Notes:

- `bootstrap.sh` installs the same package set as `linux/Dockerfile`, plus
  `libcurl4-openssl-dev` (the `swift:6.0` image already ships curl headers;
  bare Ubuntu needs them to link the release `.so`). It waits out apt locks
  (unattended-upgrades, provisioners) instead of failing on them.
- System packages do **not** survive a machine reprovision — re-run
  `bootstrap.sh` afterwards. The toolchain tarball is cached under
  `$SWIFT_TOOLCHAIN_ROOT` (default `~/swift-toolchain`), so only apt repeats.
- The lexicon cache (`.cache/`, never committed) is seeded by
  `script/prepare_lexicon.py`; its `urllib` fetch can time out on flaky
  networks while `curl` succeeds, so `test_all.sh` pre-seeds `.cache` with
  `curl` and retries on failure.
- L4's `script/linux/build.sh` and the staged-install check also run
  bare-metal; replace `script/linux/dev.sh '<cmd>'` with `<cmd>`.

## Verified facts (spike, 2026-09-28)

Each was run end to end in the dev container, so tasks can rely on them:

| Fact | Consequence |
|---|---|
| `swift build -c release --product <lib> -Xswiftc -static-stdlib` makes a `.so` with **no** Swift runtime dependencies; ~71 MB, ~56 MB stripped (aarch64). Beyond libc/libm/libstdc++/libgcc_s its only dynamic dependency was `libcurl.so.4` (FoundationNetworking, pulled in by `JevClient`; gone since Jev's removal, 2026-10-09) | Ship one self-contained `libMisstypeCAPI.so` |
| SwiftPM sets no SONAME on the `.so`; CMake still records the bare `libMisstypeCAPI.so` in the addon's `NEEDED` | Add `-Xlinker -soname=libMisstypeCAPI.so` anyway (deterministic) |
| A C target `CMisstype` (header in `include/`) imported by a Swift target lets `@_cdecl` functions take and **return C structs by value**; a C program calls them; builds on macOS too | The header is the single source of truth for the ABI (L2) |
| A C++ fcitx5 addon (`InputMethodEngineV2`, `FCITX_ADDON_FACTORY`) linking that `.so` loads in fcitx5 5.1.7 | L3 architecture |
| fcitx5's in-process harness works headlessly: `setupTestingEnvironment` + `--disable=all --enable=testim,testfrontend,misstype,testui`; typing `s u 3 c l 3` produced client preedit `你好` | L3 tests need no display or D-Bus |
| `ITestFrontend::pushCommitExpectation` **aborts the test (exit 134)** on a wrong commit | A green `ctest` is meaningful |
| `ITestFrontend::sendKeyEvent` returns whether the key was filtered (empty-composition Enter → `false`, `s` → `true`) | Pass-through (C2, C9, C10) is assertable |
| Test keys need real codes: `Key(sym, states, evdev + 8)`; `rawKey().code() - 8` is the evdev code | Keymap by scancode (L1, L3) |
| fcitx5 `Text::setCursor` counts **UTF-8 bytes** | C ABI exposes `caret_bytes` |
| fcitx5 `GlobalConfig::altTriggerKeys` defaults to `Shift_L`; in the harness a lone `Shift_L` tap (press `Key(Shift_L, {}, 50)`, release `Key(Shift_L, Shift, 50)`) switched the IC to `keyboard-us` | fcitx5 owns lone-Shift 中/英; the session's `shift_toggle` is 0 on Linux |
| fcitx5 reports modifier state **before** the event (X11 semantics) | Adapter corrects Shift's own press/release (contract §1) |
| With xkb `shift:both_capslock_cancel` (Omarchy's default, 2026-10-07 key trace) a Shift **release** arrives as keysym `Caps_Lock` with keycode 50/62 | Recognize Shift by keycode, not keysym, or a lone tap never completes (LR7) |
| On Docker Desktop for macOS, a file edited on the host can be read stale through the bind mount for a moment | If the container reports impossible errors (e.g. "unterminated #ifdef" in a complete file), rerun |

## Target layout

```text
Package.swift                         + CMisstype (C, header-only) + MisstypeCAPI (Swift, dynamic product)
Sources/CMisstype/include/misstype.h    the C ABI (Appendix A, verbatim)
Sources/CMisstype/module.c             comment-only translation unit (SwiftPM needs one source)
Sources/MisstypeCAPI/*.swift           @_cdecl implementation over MisstypeCore
Sources/MisstypeCore/KeyEvent.swift    + EvdevKeyCode, USLayout (L1)
tests/MisstypeCoreTests/KeyMapTests.swift
tests/fixtures/lexicon/lexicon.tsv    the 7-line conformance fixture
tests/capi/smoke.c, tests/capi/expected.txt
linux/Dockerfile                      dev/CI image (exists)
linux/fcitx5/CMakeLists.txt
linux/fcitx5/src/                     engine + per-IC state + candidate word
linux/fcitx5/data/addon/misstype.conf.in, data/inputmethod/misstype.conf
linux/fcitx5/data/icons/misstype-symbolic.svg  tray/IM icon (Icon=): white 隨
                                      badge, recoloured by the host; the app icon
                                      is Resources/MisstypeIcon.svg (shared with macOS)
linux/fcitx5/test/testmisstype.cpp     C1–C15 + Linux delivery rules, headless
script/linux/dev.sh                   run a command in the container (exists)
script/linux/bootstrap.sh           provision a bare-metal Ubuntu 24.04 host (no Docker)
script/linux/test_all.sh            bare-metal: swift test + C ABI + fcitx5 checks
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

**Depends on:** nothing. **Touches:** `Sources/MisstypeCore/KeyEvent.swift`,
new `tests/MisstypeCoreTests/KeyMapTests.swift`.

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

## L2: C ABI (`CMisstype` + `MisstypeCAPI`)

**Depends on:** L1. **Touches:** `Package.swift`, new `Sources/CMisstype/`,
`Sources/MisstypeCAPI/`, `tests/fixtures/lexicon/lexicon.tsv`, `tests/capi/`,
`script/linux/test_capi.sh`.

**Spec**

- `Package.swift`: add `.target(name: "CMisstype")` and
  `.target(name: "MisstypeCAPI", dependencies: ["MisstypeCore", "CMisstype"])`
  to the **always-built** targets, and the product
  `.library(name: "MisstypeCAPI", type: .dynamic, targets: ["MisstypeCAPI"])`.
  Keep the macOS-only gating as is.
- `Sources/CMisstype/include/misstype.h`: exactly the header in Appendix A
  (it compiles cleanly as C11 and C++17 with `-Wall -Wextra -Werror -pedantic`).
  Additive comment edits are fine; any signature change needs the user's
  approval because L3 and future adapters build on it.
- `Sources/CMisstype/module.c`: a single comment line.
- `Sources/MisstypeCAPI/`: `@_cdecl` implementations. Required behavior:
  - Handles are `Unmanaged` retained Swift objects passed as
    `OpaquePointer`. Every function tolerates `NULL` handles and returns
    zero values/`NULL`.
  - The engine handle owns an `InputEngine` plus a stored `SessionSettings`;
    `engine.settings` returns the stored value, and
    `misstype_engine_set_settings` replaces it (candidate keys go through
    `SelectionKeys.sanitize`).
  - Channel model (appended 2026-10-06, settings struct unchanged):
    `misstype_engine_set_channel_path` (`NULL` → `ChannelLearner.defaultURL`,
    `""` → memory only, the default after `_new`),
    `misstype_engine_set_channel_learning` (default 0; kept across
    `misstype_engine_set_settings`, still needs `user_learning`),
    `misstype_engine_clear_channel`, `misstype_engine_channel_pair_count`.
    The fcitx5 addon sets the default path; the `ChannelLearning` setting
    (default off) turns learning on.
  - Repair strength (appended 2026-10-06, settings struct unchanged):
    `misstype_engine_set_repair_strength` (0 off, 1 light, 2 standard =
    default, 3 strong; out of range ignored; kept across
    `misstype_engine_set_settings` while `fuzzy_repair` is 1). The fcitx5
    addon sets it from the `RepairStrength` setting.
  - `user_lexicon_path`: `NULL` → `UserLexicon.load()` with
    `userLexiconURL = UserLexicon.defaultURL`; `""` → empty lexicon, no URL
    (never touches disk); otherwise load/save at that path.
  - `misstype_session_handle` maps `misstype_key_event` → `KeyEvent` (kind →
    `KeyEvent.Key`, `MISSTYPE_MOD_*` bits → `KeyEvent.Modifiers` of the same
    raw value, `timestamp < 0` → `nil`, `native_code < 0` → `nil`) and
    `KeyResult` → `misstype_key_result` (`commit` via `strdup`).
  - `misstype_session_view` converts `SessionView`; `caret_bytes` is the
    UTF-8 length of the preedit's first `caret_utf16` UTF-16 units.
  - Keymap functions return labels from static storage created once (for
    example a table of `strdup`ed C strings built on first use).
  - Strings and arrays are `malloc`ed; `misstype_view_free` frees the view
    and everything in it; both free functions accept `NULL`.
- `tests/fixtures/lexicon/lexicon.tsv`: the 7 lines from
  `docs/cross-platform.md` (tab-separated, trailing newline).
- `tests/capi/smoke.c` (C11): usage `smoke <resource_dir>` runs the
  scenario script below against a fresh engine (`user_lexicon_path = ""`)
  and prints exactly `tests/capi/expected.txt`. Usage
  `smoke <resource_dir> <keys>` types each character of `<keys>` as a
  physical key (via `misstype_key_from_character`; space → `MISSTYPE_KEY_SPACE`),
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
  1. `swift build -c release --product MisstypeCAPI -Xswiftc -static-stdlib -Xlinker -soname=libMisstypeCAPI.so`
     (the same flags everywhere the `.so` is built: L3, L4)
  2. `cc -std=c11 -Wall -Wextra -Werror -ISources/CMisstype/include tests/capi/smoke.c -L<bin> -lMisstypeCAPI -Wl,-rpath,<bin> -o build/capi/smoke`
  3. `build/capi/smoke tests/fixtures/lexicon | diff -u tests/capi/expected.txt -`
  4. Symbol parity: the sorted `misstype_*` names declared in the header
     (`grep -oE '\bmisstype_[a-z_]+\(' | tr -d '('`) equal the sorted
     `nm -D --defined-only` `T misstype_*` symbols of the `.so`.
  5. `g++ -std=c++17 -fsyntax-only -x c++ Sources/CMisstype/include/misstype.h`
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

- CMake project `linux/fcitx5`, `project(misstype VERSION 0.1 LANGUAGES CXX)`
  (the name sets `CMAKE_INSTALL_DOCDIR` in L4), C++17. `find_package(Fcitx5Core)`,
  `Fcitx5Utils`, and (tests) `Fcitx5ModuleTestFrontend`. Cache variable
  `MISSTYPE_CAPI_DIR` (directory holding `libMisstypeCAPI.so`); include path
  `../../Sources/CMisstype/include`. Addon target `misstype-fcitx5`
  (`MODULE`, output `libmisstype-fcitx5.so` in `${CMAKE_BINARY_DIR}/src`),
  linked to the `.so` with a build RPATH to `MISSTYPE_CAPI_DIR`.
- Compile definition `MISSTYPE_DATADIR` =
  `${CMAKE_INSTALL_FULL_DATADIR}/misstype`; the environment variable
  `MISSTYPE_RESOURCES` overrides it (tests use the fixture).
- `data/addon/misstype.conf.in` → configured to
  `${CMAKE_BINARY_DIR}/data/addon/misstype.conf`:
  `[Addon] Name=Misstype, Category=InputMethod, Version=<project version>,
  Library=libmisstype-fcitx5, Type=SharedLibrary, OnDemand=True,
  Configurable=False`. `data/inputmethod/misstype.conf`:
  `[InputMethod] Name=Misstype, Label=隨, LangCode=zh_TW, Addon=misstype,
  Configurable=False`. The addon's name is the file's basename (`misstype`).
- Engine (`fcitx::InputMethodEngineV2`, registered with
  `FCITX_ADDON_FACTORY`):
  - Constructor: `misstype_engine_new(resources, NULL)`; apply
    `misstype_settings_default()` with `shift_toggle = 0`. If the engine is
    `NULL`, log with `FCITX_ERROR()` and pass every key through (never crash,
    never filter).
  - Per-input-context state via `fcitx::FactoryFor<MisstypeState>`
    registered on `instance->inputContextManager()`; `MisstypeState` owns one
    `misstype_session*` (freed in its destructor) and the last rendered view.
  - `keyEvent`: build a `misstype_key_event` from `event.rawKey()`:
    `evdev = code() - 8` when `code() > 8` → `misstype_key_from_evdev`; when
    that yields `MISSTYPE_KEY_OTHER` (or there is no code) and the key's text
    is one character, fall back to `misstype_key_from_character` (add
    `MISSTYPE_MOD_SHIFT` when `shifted`). `text` =
    `Key::keySymToUTF8(rawKey().sym())`, `NULL` when empty. Modifiers from
    `rawKey().states()`: `Shift`, `Ctrl`, `Alt`, `Super`/`Super2` → SUPER,
    `CapsLock`; then correct Shift keys: a Shift press adds
    `MISSTYPE_MOD_SHIFT`, a Shift release removes it. `is_release` =
    `event.isRelease()`, `native_code` = `code()`, `timestamp` = -1.
  - Apply the result per contract §2. Filtering follows the delivery rules:
    never filter releases or `MISSTYPE_KEY_MODIFIER`/`SHIFT_*` presses;
    otherwise `filterAndAccept()` iff `consumed`. `beep` is ignored.
    `mode_changed`: after rendering, set the panel's aux-up text to `英` or
    `中` (`misstype_engine_is_english`); the next render clears it.
  - Render per contract §3: if the IC has `CapabilityFlag::Preedit`, set the
    client preedit, else the panel preedit (`inputPanel().setPreedit`), as a
    `fcitx::Text` with `TextFormatFlag::Underline` and
    `setCursor(caret_bytes)`. Candidates: when `shows_candidates`, a
    `CommonCandidateList` with the `CandidatesPerPage` page size (default 8), one `CandidateWord` per entry
    whose `select()` calls `misstype_session_pick(index)` and re-renders, the
    global cursor on `selected` (its page current), labels =
    `selection_keys` when `keys_active` else empty labels. Otherwise clear
    the candidate list. Then `updatePreedit()` and
    `updateUserInterface(UserInterfaceComponent::InputPanel)`. Skip when the
    view equals the last rendered one.
  - `activate` → `misstype_session_reset_modifiers`. `deactivate` and `reset`
    always call `misstype_session_commit` (the session drops its composition)
    and render, but insert the text only when nobody else will: fcitx5
    already commits client-side preedit itself on focus out (verified in the
    harness: a second insert duplicates it), so `deactivate` inserts only for
    a switch of input method or when the context has no client preedit;
    `reset` never inserts.
- `test/testmisstype.cpp`: the fcitx5 harness pattern (verified in the
  spike): `setupTestingEnvironment(TESTING_BINARY_DIR, {"src"},
  {TESTING_BINARY_DIR "/data", TESTING_SOURCE_DIR "/data"})`, `Instance` with
  `--disable=all --enable=testim,testfrontend,misstype,testui`,
  `registerDefaultLoader(nullptr)`, an `EventDispatcher` scheduling the test
  body; set the group to `keyboard-us` + `misstype`, create an IC via
  `ITestFrontend::createInputContext`, `focusIn()`,
  `setCapabilityFlags(CapabilityFlag::Preedit)`,
  `instance.setCurrentInputMethod(ic, "misstype", false)`. Keys are
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
    `AltTriggerKeys`) and `misstype_engine_is_english` stays 0.
  Log `PASS <id>` with `FCITX_INFO()` after each; failures use
  `FCITX_ASSERT` (aborts, non-zero exit). Register with CTest.
- `script/linux/test_fcitx5.sh` (inside the container, from `/w`): build the
  `.so` as in L2, configure `linux/fcitx5` into `build/fcitx5` with
  `MISSTYPE_CAPI_DIR`, build, run
  `MISSTYPE_RESOURCES=$PWD/tests/fixtures/lexicon ctest --test-dir build/fcitx5 --output-on-failure`,
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
  addon `.so` → `FCITX_INSTALL_ADDONDIR`; `libMisstypeCAPI.so` →
  `${CMAKE_INSTALL_LIBDIR}/misstype`; the addon's install RPATH is that
  absolute directory; the configured addon conf → `…/fcitx5/addon/`;
  the IM conf → `…/fcitx5/inputmethod/`; `.cache/mcbopomofo/lexicon.tsv`,
  `.cache/mcbopomofo/toneless.tsv`, `Resources/local_phrases.tsv` →
  `${CMAKE_INSTALL_DATADIR}/misstype/`; `LICENSE`,
  `THIRD_PARTY_NOTICES.md` and `third_party/` → `${CMAKE_INSTALL_DOCDIR}`
  (the same license payload as the macOS bundle).

**Done when**

```sh
script/linux/dev.sh 'script/linux/build.sh >/dev/null && DESTDIR=/tmp/stage cmake --install build/fcitx5 >/dev/null && cd /tmp/stage && find . -type f | sed -E "s#/lib/[^/]+-linux-gnu/#/lib/<multiarch>/#" | sort'
```

prints exactly:

```text
./usr/lib/<multiarch>/fcitx5/libmisstype-fcitx5.so
./usr/lib/<multiarch>/misstype/libMisstypeCAPI.so
./usr/share/doc/misstype/LICENSE
./usr/share/doc/misstype/THIRD_PARTY_NOTICES.md
./usr/share/doc/misstype/third_party/McBopomofo/LICENSE.txt
./usr/share/doc/misstype/third_party/McBopomofo/README.md
./usr/share/doc/misstype/third_party/McBopomofo/sources.json
./usr/share/doc/misstype/third_party/NAER/LICENSE.md
./usr/share/doc/misstype/third_party/NAER/sources.json
./usr/share/doc/misstype/third_party/libtabe/COPYING
./usr/share/fcitx5/addon/misstype.conf
./usr/share/fcitx5/inputmethod/misstype.conf
./usr/share/misstype/lexicon.tsv
./usr/share/misstype/local_phrases.tsv
./usr/share/misstype/toneless.tsv
```

and

```sh
script/linux/dev.sh 'script/linux/build.sh >/dev/null && cmake --install build/fcitx5 >/dev/null && readelf -d /usr/lib/*/fcitx5/libmisstype-fcitx5.so | grep -E "RUNPATH|RPATH" && ldd /usr/lib/*/fcitx5/libmisstype-fcitx5.so | grep MisstypeCAPI && build/capi/smoke /usr/share/misstype su3cl3'
```

prints the install `RUNPATH` (`/usr/lib/<multiarch>/misstype`), an `ldd` line
resolving `libMisstypeCAPI.so` under it, and `commit=你好` (real lexicon).
Document the runtime packages (`fcitx5`, `libstdc++6`) in the
install section of `README`/this file.

---

## L5: CI

**Depends on:** L3 (and L2). **Touches:** `.github/workflows/ci.yml`.

**Spec:** keep the `core-linux` job. Add a `fcitx5-linux` job on
`ubuntu-latest` (Docker is available there) that runs
`script/linux/dev.sh 'script/linux/test_capi.sh && script/linux/test_fcitx5.sh'`.
Both checks share one container working copy, so the addon reuses the C ABI's
Swift release build. Buildx loads `linux/Dockerfile` with a GitHub Actions
layer cache (`linux-dev`); `MISSTYPE_LINUX_PREBUILT=1` tells the wrapper to use
that loaded image. Local runs still build the image by default. Tests only, no
`build.sh`: CI must not download the lexicon.

CI cancels superseded runs on the same ref. The Linux image and Pages asset
job use HTTPS Ubuntu package sources to avoid the HTTP mirror timeouts seen
on PR #26 (Pages package installation: 6m17s; Linux C ABI step including image
setup: 7m04s). Hypothesis: eliminating those timeouts and the second clean
Swift release build shortens feedback without reducing test coverage. Check
the Actions step durations on the first cold run and a subsequent cache hit;
the cache is optional and a miss must still build and run all checks.

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
   `im-config -n fcitx5`, log out and back in, add **Misstype** in
   `fcitx5-configtool`.
3. Run C1–C13 from `docs/cross-platform.md` with the **real** lexicon
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

## L7: Settings, dictionary tools, backlog

Landed 2026-10-04 (macOS Settings parity, except About):

- **Settings page**: the addon is `Configurable=True` and exposes
  `MisstypeConfig` (`engine.cpp`), so fcitx5-configtool and the KDE/GNOME
  input-method settings draw the page. Keys: `RepairStrength`
  (Off/Light/Standard/Strong), `ToneTolerance`, `UserLearning`,
  `ChannelLearning`, `MixedEnglish`, `AutoShowCandidates`,
  `ReturnConfirmsSelection`, `CandidateKeys`, `CandidatesPerPage` (4–10),
  `CursorCandidates` (Covering/EndingAt/BeginningAt), `AutoCommitSyllables`,
  `ShiftTogglesEnglish` (default off, see D1);
  stored in `~/.config/fcitx5/conf/misstype.conf`, applied to live sessions
  through `misstype_engine_set_settings` (ABI v1 gained six appended
  `misstype_settings` fields), `misstype_engine_set_repair_strength` and
  `misstype_engine_set_channel_learning`. These replace the
  `MISSTYPE_CHANNEL_LEARNING` / `MISSTYPE_REPAIR_STRENGTH` environment
  variables. Lone Shift stays with fcitx5 (`AltTriggerKeys`). Covered by
  headless scenarios LR5 (live settings, page size) and LR6 (defaults), LR7 (lone Shift to the session). The "My Dictionary" button is an
  `ExternalOption` pointing at `misstype-dictionary-editor`; whether a given
  configtool build launches a bare program name is **not verified** (open the
  editor from the app menu or `misstypectl dict gui` otherwise).
- **`misstypectl`** (Zig, `core-zig/src/ctl.zig`, tests in
  `tests/capi/ctl_test.py`): `dict list|add|remove|exclude|unexclude|check|edit|gui|path`
  edits `user_dictionary.tsv` (vChewing userdata format, `詞語 注音 [權重]`, so
  vChewing-userdata-generator output pastes in) line by line (comments survive) with
  the user dictionary's own validation; `config list|get|set|reset|path` edits
  the same `misstype.conf` the page does (values validated, unknown lines
  kept, fcitx5 asked over D-Bus to reload the addon unless `--no-reload`; `fcitx5-remote -r` would reload only the global config).
- **`misstype-dictionary-editor`** (GTK4, `linux/fcitx5/tools`): list, add,
  remove, un-hide. It owns no logic, it shells out to `misstypectl dict`. The
  reading field takes Zhuyin typed with a non-Misstype layout (typing with
  Misstype itself would produce hanzi); marking a phrase in the IME
  (Shift+←/→, Return) remains the easy way to add words. Built only when
  GTK4 dev files are present; the IME needs neither tool.
- Defaults match macOS's `MisstypePrefs` (decided 2026-10-07): auto-show
  candidates off, Return confirms a pick, mixed English off, repair
  Standard, channel learning off. The core's own defaults are unchanged, and
  the headless suite sets them explicitly before C1–C13. Not on the page
  yet: custom key bindings (`KeyBindings`, macOS Shortcuts pane) and
  clearing learned slips (`misstype_engine_clear_channel` exists; no button
  or `misstypectl` command calls it).

Backlog (not scheduled):

- IBus adapter over the same C ABI (GNOME's default IM framework): plan in
  `docs/ibus-port.md`; platform order in `docs/cross-platform.md`.
- Library size (~56–71 MB): `-Xlinker --gc-sections`, strip at install, or a
  Foundation-free core.
- Packaging: AUR recipe in `linux/aur/PKGBUILD` (published on the AUR as `fcitx5-misstype-git`;
  [Arch guide](arch-linux.md)); `.deb`, Flatpak (fcitx5 addon in a Flatpak runtime needs
  research).

## Open decisions (owner: user)

- **D1 Lone-Shift ownership on Linux.** Plan default: fcitx5
  `AltTriggerKeys` (switches to `keyboard-us`), session `shift_toggle = 0`.
  Alternative: remove `Shift_L` from `AltTriggerKeys` and let the session
  toggle its own English mode (matches macOS exactly, but needs a user-side
  fcitx5 config change). Available as the opt-in `ShiftTogglesEnglish`
  setting (2026-10-07, headless LR7); the user still disables fcitx5's
  "Temporarily Toggle Input Method" key, because fcitx5 handles that key
  before the input method sees it. Disable it with one empty entry
  (`[Hotkey/AltTriggerKeys]` `0=`): an empty list is saved as nothing and
  comes back as `Shift_L` after a restart (verified on fcitx5 5.1.23).
- **D2 Editing chords.** macOS Cmd+Backspace (clear) and Option+Backspace
  (delete syllable) map literally to Super/Alt+Backspace on Linux, where
  users expect Ctrl+Backspace. The plan keeps the literal mapping; decide
  after L6 whether the core should learn a per-platform chord table.
- **D3 Distribution channel** (L7) and whether ~56 MB is acceptable for a
  prototype.

## Appendix A: `misstype.h` (ABI v1)

Checked on 2026-09-28 with `cc -std=c11 -Wall -Wextra -Werror -pedantic`
and `g++ -std=c++17 -Wall -Wextra -Werror` in the dev container.

```c
/* misstype.h: C ABI over MisstypeCore's InputSession (docs/cross-platform.md).
 *
 * Threading: all calls for one engine and its sessions on one thread.
 * Memory: every char* and misstype_view* returned is owned by the caller and
 * must be released with misstype_string_free / misstype_view_free. Labels
 * returned by the keymap functions are static (never free them).
 */
#ifndef MISSTYPE_H
#define MISSTYPE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MISSTYPE_ABI_VERSION 1
int32_t misstype_abi_version(void);

typedef struct misstype_engine misstype_engine;
typedef struct misstype_session misstype_session;

typedef enum misstype_key_kind {
    MISSTYPE_KEY_CHARACTER = 0, /* label = US-ANSI unshifted label: "a", "1", ";", "`" */
    MISSTYPE_KEY_SPACE = 1,
    MISSTYPE_KEY_ENTER = 2,
    MISSTYPE_KEY_TAB = 3,
    MISSTYPE_KEY_BACKSPACE = 4,
    MISSTYPE_KEY_FORWARD_DELETE = 5,
    MISSTYPE_KEY_ESCAPE = 6,
    MISSTYPE_KEY_LEFT = 7,
    MISSTYPE_KEY_RIGHT = 8,
    MISSTYPE_KEY_UP = 9,
    MISSTYPE_KEY_DOWN = 10,
    MISSTYPE_KEY_SHIFT_LEFT = 11,
    MISSTYPE_KEY_SHIFT_RIGHT = 12,
    MISSTYPE_KEY_MODIFIER = 13, /* Ctrl, Alt, Super, Caps Lock, Fn alone */
    MISSTYPE_KEY_OTHER = 14
} misstype_key_kind;

/* Bit values equal KeyEvent.Modifiers raw values. */
enum {
    MISSTYPE_MOD_SHIFT = 1 << 0,
    MISSTYPE_MOD_CONTROL = 1 << 1,
    MISSTYPE_MOD_ALT = 1 << 2,       /* KeyEvent.Modifiers.option */
    MISSTYPE_MOD_SUPER = 1 << 3,     /* KeyEvent.Modifiers.command */
    MISSTYPE_MOD_CAPS_LOCK = 1 << 4
};

typedef struct misstype_key_event {
    misstype_key_kind kind;
    const char *label;    /* MISSTYPE_KEY_CHARACTER only, else NULL */
    const char *text;     /* UTF-8 the key types in the user's layout, or NULL */
    uint32_t modifiers;   /* MISSTYPE_MOD_* state AFTER this event */
    int32_t is_release;   /* 1 = key-up or modifier-only transition */
    int32_t native_code;  /* diagnostics only; -1 = unknown */
    double timestamp;     /* seconds, monotonic; < 0 = now */
} misstype_key_event;

typedef struct misstype_key_result {
    int32_t consumed;     /* 0 = the application gets the key, after commit */
    char *commit;         /* UTF-8 to insert now, or NULL (misstype_string_free) */
    int32_t beep;
    int32_t mode_changed; /* 中/英 flipped: see misstype_engine_is_english */
} misstype_key_result;

typedef struct misstype_view {
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
    /* Phrase mark (C13), appended fields: see misstype.h. */
    int32_t mark_action;        /* MISSTYPE_MARK_NONE/ADD/REMOVE/TOO_SHORT/TOO_LONG/UNAVAILABLE */
    int32_t mark_start_bytes, mark_end_bytes;   /* range in preedit, -1 when none */
    int32_t mark_start_utf16, mark_end_utf16;
    char *mark_text, *mark_reading;
} misstype_view;

typedef struct misstype_settings {
    int32_t fuzzy_repair;       /* default 1 */
    int32_t tone_tolerance;     /* default 1 */
    int32_t user_learning;      /* default 1 */
    int32_t shift_toggle;       /* default 1; fcitx5 sets 0 (AltTriggerKeys owns Shift_L) */
    const char *candidate_keys; /* NULL = "asdfghjkl;"; sanitized like SelectionKeys.sanitize */
    /* Appended fields. misstype_settings_default() keeps the core's behavior. */
    int32_t auto_show_candidates;       /* default 1; 0 = panel opens on Tab/arrows only */
    int32_t return_confirms_selection;  /* default 0; 1 = Return confirms a pick, the next Return sends */
    int32_t mixed_english;              /* default 1; needs english.tsv, else no effect */
    int32_t auto_commit_syllables;      /* default 24; 0 = never commit in chunks */
} misstype_settings;

misstype_settings misstype_settings_default(void);

/* resource_dir holds lexicon.tsv (required), local_phrases.tsv, toneless.tsv.
 * user_lexicon_path: NULL = UserLexicon.defaultURL, "" = memory only.
 * Returns NULL when lexicon.tsv is missing or unreadable. */
misstype_engine *misstype_engine_new(const char *resource_dir, const char *user_lexicon_path);
/* user_dictionary.tsv: NULL = $XDG_DATA_HOME/misstype/user_dictionary.tsv,
 * "" = memory only (the default after _new). */
void misstype_engine_set_user_dictionary_path(misstype_engine *engine, const char *path);
/* Releases the caller's handle; live sessions keep the engine alive. */
void misstype_engine_free(misstype_engine *engine);
void misstype_engine_set_settings(misstype_engine *engine, const misstype_settings *settings);
int32_t misstype_engine_is_english(const misstype_engine *engine);

misstype_session *misstype_session_new(misstype_engine *engine);
void misstype_session_free(misstype_session *session);
misstype_key_result misstype_session_handle(misstype_session *session, const misstype_key_event *event);
char *misstype_session_commit(misstype_session *session); /* NULL = nothing to insert */
void misstype_session_pick(misstype_session *session, int32_t index);
void misstype_session_reset_modifiers(misstype_session *session);
char *misstype_session_raw_phonetic(misstype_session *session);
/* 1 while an English (latin) run is open mid-composition (Shift tap or
 * backtick; InputSession.latinActive), else 0. Appended 2026-10-07: the host
 * compares it across misstype_session_handle to show 英/中 (contract §2). */
int32_t misstype_session_latin_active(misstype_session *session);
misstype_view *misstype_session_view(misstype_session *session);

/* Keymap (tables live in MisstypeCore). label receives a static string for
 * MISSTYPE_KEY_CHARACTER, else NULL. */
misstype_key_kind misstype_key_from_evdev(int32_t evdev_code, const char **label);
/* Fallback without a scancode: one UTF-8 character typed on a US layout.
 * *shifted = 1 when the glyph needs Shift ("A", "!"). Unknown: MISSTYPE_KEY_OTHER. */
misstype_key_kind misstype_key_from_character(const char *utf8, const char **label, int32_t *shifted);

void misstype_view_free(misstype_view *view);
void misstype_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif /* MISSTYPE_H */
```
