# Project outline

## Problem

Conventional touch keyboards make the user divide attention between composing and locating small, exact targets. Chinese input adds another interruption: choosing candidates while the thought is still forming. Mistype explores whether a forgiving split surface can preserve a user's learned hand motion and postpone linguistic decisions until a phrase is complete.

## Product thesis

Capture a continuous, timestamped trace of two-handed input. Interpret it as a phonetic stream with uncertainty, then decode the whole phrase. The user should be able to keep moving, pause, and receive a committed result without navigating a candidate list for every syllable.

## Scope for the first prototype

Included:

- Two independent virtual touch pads with configurable split layouts.
- Raw touch coordinates, pressure/contact state when available, timestamps, and explicit gesture boundaries.
- Zhuyin input, tone keys as optional syllable boundaries, English mode, and mixed-language spans.
- A delayed commit action and an inactivity timeout.
- Deterministic offline decoding with an optional local-model adapter.
- Trace replay, metrics, and side-by-side comparison with a conventional keyboard.

Deferred:

- Custom electronics, force sensors, haptics, and low-power firmware.
- System-wide IME integration.
- Cloud inference, accounts, sync, and social features.
- Automatic learning from personal text without an explicit opt-in and export path.

## Milestones

### M0 — Decoder seam

Feed a complete delayed phonetic stream into a decoder and emit one sentence. Use hand-authored fixtures first. This validates the core UX independently of touch hardware.

Exit: replay is deterministic; Chinese, English, and mixed fixtures produce an inspectable result; raw input remains available.

### M1 — Zhuyin capture *(prototype slice complete)*

The first keyboard adapter maps standard physical Zhuyin keys into phonetic tokens and attaches tone keys to the preceding symbol. The session coordinator now provides preview, explicit commit, pause commit, revision tracking, and model fallback. The adapter is still a trace source, not a system IME.

Remaining exit work: measure a short paragraph without per-syllable candidate selection.

### M2 — Split touch prototype

Replace buttons with two visual surfaces. Start with a known layout, then add configurable regions and generous hit areas. Record coordinates and contact trajectories, not only recognized symbols.

The known layout has landed as `full-split-1` (all 37 Zhuyin keys plus tone keys, legacy compact positions preserved), with replayable touch/keyboard fixtures under `tests/fixtures/`. Contact trajectories (`touch_move`/`touch_up`) are recorded as raw evidence without affecting decode. Still open: configurable regions. The neutral-tone gesture is answered, not open — tones are optional, see Open questions.

Exit: replaying a touch trace gives the same normalized phonetic events; compare error rate and subjective interruption against M1.

### M3 — Fuzzy spatial decoding *(keyboard-neighborhood prototype started)*

The first fuzzy layer now maps a physical key to weighted neighboring Zhuyin symbols and lets phrase decoding choose among alternatives. Coordinate-aware payloads are preferred over static keyboard neighborhoods. Phrase lookup uses a bounded same-length dictionary scan rather than Cartesian expansion, so unknown long input remains responsive. `tools/noise.py` measures the rescue rate on seeded uniform-disk jittered taps (run: `PYTHONPATH=src python tools/noise.py`). User measurements remain to be added.

Finding (synthetic, 20 seeds × 2 phrases): jitter radius ≤ 0.05 decodes at
100% with no fuzzy help needed; radius 0.08–0.15 is the fuzzy band
(+5 to +55pp over the ablated decoder, e.g. ni-hao at 0.15: 0.55 vs
0.00); radius 0.20 remains degraded (0.30–0.35 fuzzy, 0.00 ablated).
Longer phrases degrade faster, as expected from compounding per-tap error.

Follow-up, coordinate-aware payloads: distance-ranked spatial neighbors in
the touch payload (normalizer prefers them, keyboard neighborhoods remain
the fallback) widened the rescue band — ni-hao at 0.15: 0.50 → 0.70, at
0.20: 0.15 → 0.50; zao-shang-hao at 0.15: 0.25 → 0.45, at 0.20: 0.00 →
0.25. Old traces without spatial payloads replay unchanged.

Follow-up, keyboard-error battery on the real Swift decoder
(`tools/keynoise.py`, stable md5 seeds, 10 seeds/cell; ms column is process
spawn+lexicon load, engine decode stays 0.1–25 ms in-process): short inputs
are robust (ni-hao/wo-shi-xue-sheng: clean/no-tones 1.00, drop/swap/sub
0.50–1.00, harsh 0.30–0.60). The cliff is 9-syllable input under key loss:
dada drop-key 0.70, swap 0.20, harsh 0.00 (recall collapses with top-1, so
rescoring cannot recover). Dada toneless stays top-1 0.00 / recall 1.00 —
pure word-frequency (大對), not structure. Lattice caps are now cost-ranked
and a repair track runs only when the clean merge is not fully clean, so
clean input pays nothing extra. A `yue-lai-yue-phonetic` probe locks the new
phonetic-confusion class (ㄧㄨㄩ taps as u/j/m): recall 1.00 clean and
toneless, 0.80/0.50/0.40/0.20 under drop/swap/sub/harsh noise — top-1 stays
frequency-decided and needs the window or context. Lesson: cross-run
battery comparisons need stable seeds — Python `hash()` is salted per
process and once faked a regression.

Exit: report accuracy, correction rate, latency, and the point at which fuzziness stops helping.

### M4 — Local model and optional LLM

Add a local sentence decoder behind the same interface. An explicitly enabled LLM adapter may rerank or repair a completed trace, but must time out to the offline result and never block capture.

The adapter seam has landed without weights: `DecodeContext` (revision + deadline + cancellation), `DecoderProtocol`, and `decode_with_fallback` (offline-first, bounded to one cancellable adapter slot, rejects slow/failed/stale results). A `StubModelAdapter` proves a 5 s model behind a 10 ms deadline still returns the offline text in well under a second. Remaining: model choice, latency budgets, and provenance surfacing.

Finding (local-LM repair falsified, 4 synthetic cases, `tools/lm_rescore.py`):
qwen2.5 0.5b/1.5b via localhost ollama, temp 0, repair-mode with a
verify-then-accept gate (same length + per-char toneless-base match).
Zero top-1 flips: 2 verbatim echoes, 1 near-miss pick (答對 for 打對,
defensibly fluent), 2 hallucinations correctly gated to fallback
(海 for 測, 汝 for 你). Warmed latency 0.6–2.7 s per sentence — usable
only behind the async deadline seam, never inline. Lesson: the offline
decoder's job is recall (truth in top-N, now top-8), and any generative
adapter ships only with the verification gate. Next lever with proven
ROI is a visible candidate window over the existing top-8.

Finding (scoring rerank falsified for qwen2.5 ≤1.5b instruct,
`tools/lm_rerank.py`, llama.cpp server + local GGUF, char-trie edge
scoring): bare-prefix scoring flipped 打對 but was methodologically
unsound (instruct model without template puts mass on 答案/Engl-style
continuations; targets routinely miss top-200). Chat-template scoring
is clean and fast (4–6 requests, 60–840 ms) but flips nothing —
0.5b and 1.5b agree, controls hold. Verdict: instruct-tuned ≤1.5b
models cannot rank single-character continuations reliably; rerank
needs base (non-instruct) weights or bigger iron. The seam, protocol,
and fixtures stay — the model choice (M4 open question) is still open.

Finding (corpus bigram falsified decisively, 6.8M-dialogue LCCC/MIT
counts via `tools/corpus_bigram.py`, same uniform mechanism as the
wordlist run): the table loads (2.2M pairs) and the mechanism runs,
but full sentences degenerate into common-char soup
(A-case: 策是一下回不回答對 repairs=3; long: 好哦先在看看回不回…),
because per-char bigram variance (±several points × 26 syllables)
steamrolls word scores, tone exactness, and repair penalties alike.
Pair margins confirm it: 不打/不大 11784/10663 (Δlog 0.1, needs β>12
against word Δ1.18 — no sane weight works), 以辨/以便 17/308 and
識成/是成 0/4009 (adversarial both sides), 功嗎/功麼 unattested.
QingJian ships this shape successfully — likely because pinyin input
has no tones, so bigram carries load that tones already carry for us,
and because of careful interpolation we did not build. Lesson: for
tonal Zhuyin fuzzy input, n-gram context is the wrong lever; the
residual ties (不大/便是/麼/大隊) need user signals — phrase learning
(explicit opt-in) or the visible window — not a bigger count table.
Reverted fully (scores byte-identical to pre-experiment); the script
and counts stay under ~/.cache as the negative-result record.

Finding (trigram rerank falsified, same protocol via `tools/tri_rerank.py`,
18M distinct trigrams from the same LCCC run): 0 flips, active damage —
打對 falls to 測試以下會不會大對, 辨識 to the 哦-variant. Mechanism:
only 2 of 17 needed trigrams are attested (formal phrasing absent from
casual dialogue), so floors decide and the colloquial bias (哦, 以下)
wins ties; controls hold only via the acoustic tiebreak. The count
family is dead for this job (wordlist-bigram adversarial, corpus-bigram
steamrolls, trigram sparse-and-colloquial). Remaining honest levers:
user phrase learning (deterministic, explicit opt-in) and the visible
window (shipped); neural rerank needs base weights or bigger iron.

Exit: offline mode is useful on its own; model provenance and timing are visible in measurements.

### M5 — macOS Input Method adapter *(prototype slice landed)*

Package the stable core behind a thin macOS InputMethodKit adapter. `IMKServer` and `IMKInputController` own system integration; they forward key events into the core and send committed text back to the client app. Keep marked text, commit/cancel, language switching, and preferences in the adapter. Do not put fuzzy decoding or model calls in AppKit code.

The first native InputMethodKit bundle is installable through `script/install_ime.sh`. It uses a pinned offline dictionary, whole-composition segmentation, conservative fuzzy rescue, marked text, Return/Space commit, Backspace, Escape, and Latin passthrough. It is a real system-wide experiment, but not yet a production IME: user phrase learning, richer punctuation, robust candidate UI, signing/notarization, and shared Python/Rust decoder integration remain open.

### M5 roadmap — candidate window v1 landed, refinements queued

v1 shipped: single-row `IMKCandidates` panel auto-shows on >1 candidate;
Tab/Up/Down step, Return commits, click selects, Escape hides. Thesis
holds — the panel stays out of the way when top-1 is right.

Queued from typing feedback (falsify each with a manual check, keep the
window out of the critical path):

1. Panel direction + sync (resolved with a custom window): `IMKCandidates`
   proved undrivable — `selectCandidateWithIdentifier:` returns YES and
   moves nothing, synthesized stepping events only beep (both verified in
   the file trace). Replaced by an owned borderless `CandidatesPanel`
   (vertical list, caret-following, click-to-pick); highlight is single
   source of truth by construction. Remaining polish: single-column vs
   current rows styling, Spotlight-level edge cases.
2. Digit selection (landed, superseded by item 3 below): Shift+2..8 selects without committing (same as
   click/Tab; typing on commits via the sticky pick), active only while the
   window is up so digits stay phonetic otherwise. Shift+1 stays ！ —
   candidate #1 needs no shortcut.
3. Letter-row selection (designed, not built): switch to `asdfghjkl;`
   selection keys, user-configurable string like McBopomofo's
   `candidateKeys` preference. Conflict analysis: those keys ARE Zhuyin
   initials, so modeless auto-show + letter-select cannot coexist — pair
   this with a Tab-first-show invocation model: the window appears only on
   explicit Tab, and only then do letter keys select; Esc or typing outside
   the key set resumes composing. This retires Shift+digit entirely
   (digits return fully to phonetic/punct) and ends the last Shift
   conflict. Falsify with: Tab → `a` picks #1 without committing; `m`
   with window closed still types ㄇ.
   Page turning needs candidates beyond the visible 8: widen the beam only
   after measuring that missing truths (不打/嗎) rank within reach —
   otherwise paging just flips through junk.
4. English switching: Shift-hold Latin appends inline and Shift+Space
   toggles exist; collect the exact broken cases (mode indicator? CapsLock?
   toggle state after commit?) before changing behavior.
5. Punctuation (v1+v2 landed + pin-continue): CJK table in `Sources/MistypeCore/Punctuation.swift`
   (，的那 Shift+`,`/`.`/`/`/`;`/`1`, 「」『』 on quote/bracket keys,
   、· on `\`, ； on Ctrl+`;`, —— on Shift+`-`). Zhuyin-position keys stay
   phonetic so syllable-initial ㄝㄡㄥㄤㄦ keep working; separators pin the
   current pick and continue (commit is Return's job); Cmd shortcuts never
   hijacked. Follow-up: … needs a conflict-free key (Option layer).
6. Seamless mixed input (v1 landed): backtick toggles a latin run — letters
   append verbatim (`L:`-marked keys, case preserved), spaces stay inside
   multi-word runs (`` `hello world` ``), tones/punct/digits/Return end the
   run, one commit at the end. No Shift toggle, no pause:
   `` `hello world`su3cl3 `` → `hello world你好`. Guessing is impossible by
   construction (bare keys stay Zhuyin), so `hello`-as-keys still decodes
   Chinese — auto-detect with English scoring stays future work, as do
   digits-inside-latin.

## Measures

Track phrase-level character error rate, syllable error rate, commit latency, p50/p95 decode latency, backspaces or replays, candidate interruptions, and task completion time. Log confidence and decoder source for every result. Run a fixed synthetic fixture set plus consented user sessions kept outside the repository.

The main comparison is not raw key accuracy. It is whether users can capture thoughts with fewer interruptions at an acceptable final reconstruction quality.

## Open questions

- Does tone input improve segmentation enough to justify a dedicated gesture?
  Finding (fixture-backed, 9-phrase table): no. Tones are optional hints —
  exact-tone matches decode at confidence 1.0, unique toneless matches at
  0.6, ambiguous toneless input stays a visible bracket fallback. No
  dedicated neutral-tone gesture while ambiguity stays near zero; revisit
  with a larger table or user data.
- Which split layouts match existing Zhuyin muscle memory across hand sizes?
- Should a pause commit automatically, or only preview a reconstruction?
- How should Latin text, numbers, punctuation, and code tokens interrupt a Zhuyin span?
- What local model size meets the latency budget on the target device?
