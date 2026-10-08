# Zig port of MisstypeCore

Status (2026-10-08): step 0 done; step 1's keyboard session and C ABI are
ported and verified against Swift on synthetic keyboard replays. Touch and the platform cutover
remain open. Swift `MisstypeCore`
stays the single source of truth until the Zig engine matches it and a
platform has switched over.

## Why

The Zig rewrite is not mainly about speed. The goals are:

- **Setup:** one pinned toolchain download instead of a Swift 6 toolchain
  (or the 3.7 GB Linux dev image).
- **Cross-compiling:** every target from any host.
- **Shipping:** no Swift runtime inside the Linux `.so`.
- **C ABI:** exporting C functions is built into the language, so no
  `@_cdecl` layer.
- **Wasm:** a small wasm build for the site demo without the SwiftWasm SDK.

## Size of the job

- `MisstypeCore`: about 6,400 lines of Swift (`InputSession` 1,483,
  `Lexicon` 862), plus about 4,600 lines of tests.
- fcitx5 uses only the C ABI (`Sources/CMisstype/include/misstype.h`,
  25 functions). A Zig library that exports the same header can replace
  the Swift one without any change on the fcitx5 side.
- The macOS IME (6 files), `misstypectl` and the Wasm demo import Swift
  types directly. They would have to move onto the C ABI, and the ABI
  would have to grow.

## Costs and risks

- **Zig is pre-1.0.** Every release breaks APIs (0.16/0.17 rewrote I/O
  around `std.Io`). The version is pinned in `script/zig/bootstrap.sh`, and
  upgrades are deliberate commits.
- **No Unicode text handling in the standard library.** Swift `Character`
  and `String` semantics have to be reproduced by hand. So far, comparing
  bytes in UTF-8 order plus counting UTF-16 lengths for alignment is enough,
  because the core already orders text by UTF-8 bytes.
- **Library replacements:** Foundation features (JSON, file access,
  `URLSession` in `JevClient`) need Zig equivalents.
- **Manual memory management.** The decoder allocates everything for one
  decode in an arena that is freed in one step.
- **Silent integer overflow in fast builds.** `@min(x, comptime_value)`
  narrows to the smallest integer type that fits: `@min(len, 15)` is a
  `u4`, and `+ 1` overflows. Debug builds trap on this; ReleaseFast wrapped
  it silently and corrupted the beam during step 0. Run tests in Debug and
  annotate the result type of a `@min`.
- **Two engines drift apart.** The Python prototype already showed this.
  The comparison harness is what keeps the two in step, and the plan ends
  in a cutover, not long-term maintenance of both.

## Plan

0. **Quick test (done, below).** Pinned toolchain, `core-zig/` package,
   lexicon loading and exact decoding ported, compared against Swift
   (`core-zig/bench/compare.sh`). The test would fail if decoding were
   clearly slower than Swift, or if matching Swift's text handling got ugly.
1. **Full `InputSession` port behind the same `misstype.h`.**
   - First, grow the comparison into a replay tool: key sequences go
     through both the Swift `MisstypeCAPI` and the Zig library, and every
     `SessionView` and key result is compared.
   - Then port: edit repair, segmentation of toneless key runs, user
     lexicon/pins, mixed English, touch.
   - The fcitx5 C1–C15 suite runs against the Zig `.so`, and Linux
     switches over.
2. **macOS IME, `misstypectl` and Wasm move onto the C ABI.** The ABI
   grows to cover config and user-dictionary editing.
3. **Remove the Swift core** and update `AGENTS.md`, `architecture.md` and
   `cross-platform.md`.

## Step 0 results (2026-10-08)

Ported: the lexicon trie, toneless overrides, exact/toneless/tone-tolerant
reading options, and the 16-wide decode beam with the word penalty. This is
the `fuzzy: false` path with no user lexicon (`core-zig/src/lexicon.zig`,
about 330 lines including tests, against about 500 for the Swift
equivalent).

Inputs: the 42 probes in `tools/baseline/probes.tsv`, each run toned and
with tones stripped (84 inputs, 2–17 syllables; `core-zig/bench/inputs.tsv`).
Lexicon: the shipping lexicon, 112,439 entries. Machine: aarch64 Linux
(Ampere). Swift 6.0 runs a `-c release` build in `misstype-linux-dev`;
Zig runs ReleaseFast on the host. Docker adds no CPU overhead on Linux.

| | Swift | Zig |
|---|---|---|
| Output | reference | **1,344/1,344 candidates identical** (text, score bits, repairs, alignment) |
| Lexicon load | 1,304 ms | 57 ms |
| Decode, mean / p50 / p95 / max | 581 / 576 / 925 / 1,289 µs | 40 / 40 / 66 / 94 µs |
| Zig built for baseline CPU | | 37 µs mean (same) |

The decode speedup is about 14×. It is not all Zig: the port uses interned
reading ids and integer-keyed trie edges, where Swift uses `String`-keyed
dictionaries. Swift could adopt the same data structures. Expect the gap to
narrow once repair and the user lexicon are ported.

Developer experience:

| | Swift (today) | Zig 0.17.0 |
|---|---|---|
| Toolchain setup | `swift:6.0` image 3.1 GB (dev image 3.7 GB) | `script/zig/bootstrap.sh`: 13 s, 398 MB unpacked |
| First build on a fresh machine | 43 s for the C ABI library in the container | 133 s (Zig compiles its build system and runtime libraries once per machine, then caches them) |
| Edit, then test | not measured | 4.5 s (Debug) |
| Cross-compiling | per-platform toolchain or SDK (SwiftWasm 6.0.3) | from aarch64 Linux, 6–9 s per target: x86_64-linux, aarch64-macos, x86_64-macos, wasm32-wasi, x86_64-windows |
| Size of what ships | `libMisstypeCAPI.so` 73 MB (56 MB stripped; static stdlib + Foundation) | bench executable 140–540 KB (ReleaseSmall); the decoder is a small part of either |

The sizes compare the full Swift C ABI library with the Zig decoder plus
its bench, so they are not like for like. Most of the 73 MB is the Swift
and Foundation runtime, and the C ABI library will stay far below that.

Not checked yet: whether the cross-compiled binaries run on their targets
(they only build here); the size of the current SwiftWasm build; a real Mac.

Verdict: step 0 passes. The port matches Swift exactly, is faster, and sets
up in seconds. The costs found so far are the pre-1.0 churn and the
integer-narrowing trap described above.

## Commands

```sh
script/zig/bootstrap.sh                                 # pinned Zig into .cache/zig
(cd core-zig && "$(../script/zig/bootstrap.sh)" build test)
core-zig/bench/compare.sh [repeats]                     # Zig vs Swift (Docker)
MISSTYPE_SWIFT_HOST=1 core-zig/bench/compare.sh         # Swift on the host (macOS)
core-zig/bench/replay.sh [fuzz-cases] [seed]           # full C ABI replay vs Swift (Linux)
MISSTYPE_ZIG_OPTIMIZE=ReleaseFast core-zig/bench/replay.sh # optimized replay + latency
script/zig/test_linux.sh                              # Zig C ABI + fcitx5 in Docker
```

## Step 1: keyboard session and C ABI (2026-10-08)

Hypothesis: the offline keyboard session can preserve Swift's behavior
behind the existing `misstype.h` without changing the fcitx5 adapter. The
smallest falsifier is a synthetic key replay through both libraries,
comparing key results and views after every event. `bench/replay.sh` grows
that check into the conformance scripts, all 42 probe sentences (toned,
toneless, and edited), English/mixed cases, and 400 seeded random sessions
under 11 settings combinations. Generated scripts and transcripts live in
`build/replay/`; they contain only synthetic inputs.

Ported: composition/editing, live conversion, repair and segmentation,
candidate pages, syllable cursor/pins, phrase marking, user dictionary
overlays, word/context learning, the personal channel model, punctuation
and symbol menus, Shift-tap/Latin recovery, chunked commits, mixed English,
and the 25 C ABI functions. Zig builds `libMisstypeCAPI.so`; the existing
header and fcitx5 adapter are unchanged. User data remains local.

The initial Debug replay matched all 41,064 transcript lines. It caught
two Zig-specific bugs before passing: a narrowed integer loop bound in
repair fallback overflowed, and changing a tagged union to Latin read its
old field during reassignment. Both have focused regression tests. A
tracking-allocator session test also covers engine retention and freeing
refresh/selection allocations. The replay driver now checks intermediate
views inside multi-key script lines as well, and reports time spent in
`misstype_session_handle` separately from view rendering and resource load.

The stronger Debug and ReleaseFast replays match **48,078/48,078 transcript lines**
over **13,524 key events** (400 random sessions, seed 1, plus conformance and
probes), including intermediate views. All decoding is offline. Indicative
single-run handle latency on aarch64 Linux: Zig mean **226.5 µs**, max
**32.7 ms**; Swift release mean **2,729.7 µs**, max **478.3 ms**. These runs
include mixed English and malformed input; they exclude resource loading,
view calls, and the reference's English-load waits. The machine was shared
with other checks, so this is not a controlled latency distribution.
The exact-decoder gate still matches all **1,344 candidates bit for bit**
(text, scores, repairs, unresolved counts, alignment); means on this rerun
were Swift 581.1 µs and Zig 43.3 µs.

Validation: the Zig library passes the C ABI smoke transcript and exported
symbol check, plus all 19 headless fcitx5 scenarios. The full Swift/Linux
suite also passes (270 Swift tests, 9 skipped, C ABI and fcitx5). These checks
exercise in-memory dictionary and learning behavior; persistent-file parity
needs a dedicated differential check before cutover.

Remaining scope: touch decoding, custom key bindings (not exposed by the
current C ABI), Jev assistance and diagnostic logging, and dev-only bigram
and lexicon overrides. English resources load synchronously in Zig, while
Swift loads them in the background; the reference replay waits for that
load. No platform default or installer has switched to Zig. macOS,
`misstypectl`, Wasm, and running cross-compiled binaries are still later
milestones.

## CI and remaining cutover work

CI runs on pull requests, pushes to `main` and `zig-core-spike`, and manual
dispatch. `zig-core` checks formatting and unit tests in Debug and
ReleaseFast. `fcitx5-linux` retains the Swift checks and also runs the Zig
C ABI smoke/symbol checks, all addon scenarios, exact candidate parity,
and 400-session replay parity in both build modes. It downloads only the
checksum-pinned public dictionaries; toolchain/compiler and source caches
are separate. Failed replay transcripts are synthetic and retained as CI
artifacts for seven days. There is no remote decoder in these gates.

Hypothesis for CI integration: the existing local gates run unchanged on a
fresh x86_64 Linux runner. A branch CI run is the falsifier; successful
aarch64 local checks alone do not establish hosted-runner portability.
Latency is reported for observation, without a machine-dependent pass
threshold. Release and Pages still build their Swift consumers; Zig passing
CI does not change what either workflow ships.

The complete port has these remaining boundaries, in dependency order:

| Area | Current evidence / gap | Exit check |
|---|---|---|
| Keyboard correctness and memory | Synthetic C ABI replay matches; Swift's full test coverage is broader than the 19 Zig unit tests. Unicode, malformed resources, engine/session lifetime, and long compositions need broader coverage. | Replay additional seeds and focused fixtures; check allocations and long-running memory use. Preserve Swift's behavior on every regression. |
| Persistent user data | Dictionary overlays and learning work in memory; JSON/TSV parsing exists, but file interoperability is unproven. | Round-trip synthetic phrase/channel/dictionary files in both directions, restart engines, test mtime reload, legacy formats, bad files, and failed writes without losing valid data. |
| Touch | No Zig equivalent of `Touch.swift`'s mapper, beam, or spatial lattice. | Replay the same seeded taps through Swift and Zig, compare hypotheses/candidates/costs and the existing accuracy/latency measurements. Raw coordinates remain evidence. |
| Linux build and distribution | fcitx5 can use the Zig library in tests. `build_capi.sh`, `build.sh`, desktop installer, and AUR packaging still build Swift. `misstypectl` is also Swift. | Build/install an opt-in Zig backend first, verify dependencies and data paths, run conformance and real desktop typing, then switch the default. Migrating the CLI is needed to remove the distribution's Swift dependency completely. |
| C ABI and macOS | The current ABI lacks clause segments/focus, the Latin-toggle result flag, custom bindings, host/context callbacks, and dictionary/learning editor operations used through Swift types. | Extend/version the ABI and test ownership/layout compatibility; move the IMK adapter and Settings onto it without changing UI behavior. Verify caret, marked clauses, popup clients, dictionary editing, and sandbox paths on a real Mac. |
| Optional assistance and diagnostics | Jev's opt-in asynchronous path, context/deadline/revision handling, core logs, and dev-only bigram/lexicon overrides are unported. | Preserve these seams or explicitly decide their future. Network transport can remain in an adapter, but async results must remain revision-safe and offline/default-off behavior unchanged. |
| Wasm and shipping | The site imports Swift and uses SwiftWasm. Step 0 cross-compilation only established that the smaller decoder built; the expanded C ABI/session has not been validated on each target. | Run the full core on target architectures, migrate browser bindings and Pages assets, check size and latency, then update macOS packaging to link/sign both architectures and test a signed/notarized install and update. |
| Final removal | All production consumers still depend on Swift `MisstypeCore`. | Remove it only after consumers and regression tools use the replacement; update architecture, cross-platform contracts, commands, licenses, and release docs. Retain replay fixtures and an explicit replacement for the Swift reference gate. |

The next work after CI is persistent-file interoperability, then touch and
an opt-in Linux build. macOS ABI expansion and consumer migration follow;
release packaging changes belong with that migration. Product experiments
(human tap spread and real mixed-language typing quality) remain open
independently of the language port.
