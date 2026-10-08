# Zig port of MisstypeCore

Status (2026-10-08): step 0 done; step 1 not started. Swift `MisstypeCore`
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
  26 functions). A Zig library that exports the same header can replace
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
```
