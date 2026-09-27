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
user phrase learning (deterministic, local-only, now default-on) and the visible
window (shipped); neural rerank needs base weights or bigger iron.

Finding (choice rerank falsified, `tools/lm_choose.py`, localhost ollama,
temp 0, strict index-parse with abstain-to-offline): repair asked for
generation and scoring asked for calibration — choice asks only
discrimination (pick one number from the offline top-8, hallucinations
unrepresentable). Still dead. 1.5b: 0 flips (dada truth #8 打對 sits in
the list, model picks #6 答對), 1 WORSE — the lone clean control 你好
gets replaced by ㄋㄧˇ好, junk containing raw Bopomofo: the model cannot
even recognize well-formed Chinese. 0.5b: 0 flips, 3 WORSE (你好→擬好,
大對→大堆), always-vote-#3 position bias, 0 abstentions across both
models (they always vote, even wrongly). yue (truth outside top-16) stays
junk→junk as designed. Warmed latency 73–485 ms (1.5b; first call 5.4 s
cold) — faster than repair-mode, moot on quality. Verdict: instruct-tuned
≤1.5b is now 0-for-3 framings (generation, scoring, choice); neural rerank
still needs base weights or bigger iron. Side calibration: nihao-wrongtone
resolves to 泥好 (CER 0.5) on the real 112k lexicon — the old "wrong tone
recovers to 你" finding was fixture-lexicon-backed and does not transfer;
future controls must be cut against the real table.

Finding (Jev choice, `tools/lm_choose.py --backend jev` + `tools/jev_choice.cjs`,
Vercel AI Gateway `typesafe-ai/jev`, 5 cases x 3 reps): architecturally the
cleanest fit yet — typed Choice over the top-8 (no text, no parse), native
probabilities, 307–585 ms in-model, ~8.6k input tokens total (~$0.0004).
Behaviorally: safe but useless. 0 flips, 0 WORSE, 0 abstains, bit-identical
picks across reps. Controls hold at sane confidences (你好 1.0 x3,
junk-vs-junk ~0.5). But dada repeats the qwen miss almost exactly — #6 答對
at 0.97 x3 with truth #8 打對 sitting in the list. A 0.97 on the wrong
answer is a calibration data point against RLCD claims outside their
workflow distribution (n=1 case, not a calibration study — stated as such).
Confidence-threshold abstain changes nothing on this set (all picks >= 0.5,
nothing WORSE to save). Verdict: Jev passes the safety bar qwen failed
(never regresses, deterministic) but fails the flip bar all the same;
the 答對/打對 class needs a user signal (learning/window), not a better
voter. Toolchain note: Gateway evaluation is AI-SDK-only (no REST), so the
backend is Python-orchestrated + thin node helper with a self-bootstrapping
`ai` package (never vendored); ESM import ignores NODE_PATH, hence `.cjs`.

Follow-up (flow design falsified too, `--jev-mode noul`): TypeSafe's own
guidance says to decompose into parallel atomic questions combined in code,
so the same 5 cases ran as 8 parallel boolean Nouls per request with code
argmax. Identical picks to single-Choice on all decidable cases (long #1,
dada #6 答對 at 0.86–0.88 with truth #8 at 0.16–0.18, wrongtone #1, toned
#1 at 0.89–0.90); only pure-junk yue wobbles (#1 vs #6, max ~0.3 — honest
low-confidence disagreement, same CER). Mechanism is not the blocker: two
flows agree, both confidently wrong on dada. One constructive signal: Noul
max-prob reads as a usable uncertainty meter (0.9 clean / ~0.5 mid / ~0.3
junk), better behaved than Choice's 0.97-on-wrong — if Jev ever assists,
Noul-argmax with a threshold is the right shape. Standing verdict across 2
models x 4 framings (generation, scoring, choice, decomposed-noul): the
答對/打對 class needs a user signal, not a better voter.

Pilot (triage, NOT a finding yet, `--jev-mode trust`, n=5, threshold 0.6
read post-hoc): one boolean on offline top-1 ("候選1是最正確的嗎")
separates 10/10 — right top-1 trusts 0.82+ (hide-panel), wrong top-1
0.10–0.52 (show-panel), 293–598 ms, one question per pause. Partially
right long-toneless lands 0.52, i.e. the meter tracks graded correctness,
not just binary. If this holds on the wider keynoise battery with a FROZEN
threshold, the honest Jev job is interruption triage (drive panel
auto-show), never reranking: a miss-show is status quo, a miss-hide is a
regression vs today, so the threshold must bias toward showing. Remote use
stays explicit opt-in per repo policy; nothing wired into the IME yet.

Battery (`tools/lm_trust_battery.py`, frozen 0.6, 4 probes x 6 configs x
10 seeds = 240, ~$0.005): hits=213, miss_show=0, miss_hide=27 -> DO NOT
WIRE. trust|correct floor holds beautifully (mean 0.91, min 0.81, n=108 —
the meter never doubts a right top-1), but trust|wrong reaches 0.96: the
meter measures fluency, not correctness, so fluent-but-wrong ties (dada
sub/swap cells) hide the panel exactly where the user needs it most. Dump
(`--dump-misses`) shows it is worse than subtle ties: trusted top-1s at
0.60–0.87 include literal Bopomofo fallback (會ㄅˊ會, ㄏㄨㄟㄅˋ無會,
打ㄨㄉㄟˋ, 測字一蝦) from realistic single-key typos — a trust gate blind
to visible garbage is unusable, not just unhelpful. Same
root cause as every prior falsification, one level up. No threshold rescue
claimed here (tuning on this battery would be overfitting; a new threshold
needs fresh seeds). Standing order: triage stays an offline meter until a
replacement signal separates fluent-wrong from fluent-right.

Follow-up (evidence-aware harness, 5 cases x 3 reps, `tools/lm_choose.py`):
the original Jev call accidentally passed an empty evidence string, so the
model only saw candidate text. The harness now sends the raw key stream,
pinned-dictionary Zhuyin readings with attached tones, offline rank/score and
repair metadata, plus optional explicitly supplied context or matching local
phrase-learning entries; it also reports candidate recall separately. On the
corrected top-8 run, recall was 2/5 and
all 15 Jev picks stayed at offline top-1 (0 flips, 0 worsens). This confirms
the missing-evidence bug was real, but adding evidence alone does not resolve
the remaining fluent homophone ties or candidates absent from the beam.

Prompt sweep (`tools/jev_prompt_sweep.py`, 3 variants x 3 reps on 3 synthetic
cases): structured, hard-constraint, and contrastive instructions were all
stable and identical on the contextual holdout — the rank-8 `打對` tie stayed
at rank 1 despite context describing an input-method test. A synthetic
learned preference for the full `打對` phrase moved all 9 trials to rank 8
under every variant, with no regressions. Prompt wording is therefore not the
useful lever; an explicit user signal is.

Rich-context follow-up (4 variants x 3 reps on 4 synthetic cases): the state
also included per-character phonetic alignment, changed positions, and the
decoder contract. This added metadata did not move the generic contextual
holdout: all 12 calls stayed at rank 1. A second holdout with explicit
action-versus-size intent moved the rank-8 `打對` candidate once under the
structured prompt; two structured calls completed (one moved to rank 8 and one
stayed at rank 1), while the third hit the fixed timeout and abstained. The
hard-constraint, contrastive, and rich-audit arms stayed at rank 1. The learned
preference still moved all 12 of its calls to
rank 8. Across 48 calls there were 0 WORSE results; gateway calls generally
completed in roughly 0.3–0.5 s, with one fixed 120 s timeout. More JSON is not
the fix: useful semantic context can help, but the signal must explicitly
describe the intended sense and the conservative prompt can suppress it.

Local Jev replacements (2026-09-27, `--backend jev-local`, 12 synthetic cases
x 1 rep, M3 24 GB, loopback only): the same Choice job (`jev_choice_job`, the
state and criteria sent to hosted Jev) was POSTed to open-weight
Jev-compatible servers. Hypothesis: a local model keeps hosted Jev's
0-WORSE safety within an IME-sized deadline, so there is no request to pay
for. Falsified on both. Laya `laya-multilingual` (322M encoder, MPS): 0
flips, 6 WORSE (including the `不大` control -> `布大`), confidences mostly
0.3–0.5, 120–600 ms warm. jev-local with Qwen2.5-3B-Instruct HF logprob
scorer: 2 flips (辨識, 做作業), 4 WORSE (大對 -> 大堆 x3, 大錢包 -> 大前包),
11–80 s per request (one forward pass per option, no KV reuse). For
reference, the WIP candidate-only `ollama-logprobs` qwen2.5:1.5b arm gave 1
flip / 6 WORSE / 1 abstain at ~0.1 s (it does not see phonetic evidence, so
it is not an apples-to-apples comparison). Hosted Jev stays the only
voter that never regressed. Nothing is wired into the IME; the local path
remains a tools-only experiment. Setup notes: jev-local defaults to a
deterministic stub scorer (`JEVLOCAL_SCORER=hf` is required), its `[hf]`
extra omits `accelerate`, and both servers bind `0.0.0.0` by default, so
run them with a loopback host.

Exit: offline mode is useful on its own; model provenance and timing are visible in measurements.

### M5 — macOS Input Method adapter *(prototype slice landed)*

Package the stable core behind a thin macOS InputMethodKit adapter. `IMKServer` and `IMKInputController` own system integration; they forward key events into the core and send committed text back to the client app. Keep marked text, commit/cancel, language switching, and preferences in the adapter. Do not put fuzzy decoding or model calls in AppKit code.

The first native InputMethodKit bundle is installable through `script/install_ime.sh`. It uses a pinned offline dictionary, whole-composition segmentation, conservative fuzzy rescue, marked text, Return/Space commit, Backspace, Escape, and Latin passthrough. It is a real system-wide experiment, but not yet a production IME: richer punctuation, robust candidate UI, signing/notarization, and shared Python/Rust decoder integration remain open.

User phrase learning v1 has landed (default on, opt-out in Preferences;
local only; superseded 2026-09-27 by word-level + context learning, store
v2 — see M5 item 9): an
explicitly picked candidate committed on a single pure-Zhuyin run is
recorded locally and boosted next time (+6 / +1 per repeat / cap +10).
Falsified with `--decode --user-lexicon`: one 妳好 record flips top-1
(#4 → #1, 9 syllables, decode stays <1 ms, offline source). v1 limits:
pure runs only (mixed/latin/space-separated spans skip), commits with a
pending tail skip, segment-lock heads never train, 500-entry LRU cap.
Measure with: `MistypeIME --decode "<keys>" --user-lexicon <path>`.

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
3. Letter-row selection (landed 2026-09-27, manual check pending): the
   window still auto-shows while typing, but its key labels are dim and the
   selection keys (Preferences, default `asdfghjk` — one page of 8) pick
   only in selection mode: after Down/Up/Tab, or in the syllable cursor's
   list. Picking, Esc, or typing any other key leaves the mode; the first
   Esc keeps the text. Shift+digit no longer picks: the Shift row is the
   full-width layer ＠＃＄％︿＆＊（）＋｛｝～ (大千 convention). Original
   design note: switch to `asdfghjkl;`
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
   Update (measured, landed): width-16 keeps 不打 #14, 嗎 #9, 打對 #8 at
   ~50 ms for 26 syllables, so the beam widened to 16 and the panel shows
   a window of 8 around the selection — Tab/arrows/digits walk the full
    list, Left/Right flip pages (same row, clamped), footer shows `n / m`.
    Panel frame hugs content (rows or preedit header, 300pt cap) with x
    sticky per visible session and y bottom-anchored to the caret line —
    resizes ease instead of snapping; height fits shown rows (plus the
    preedit header) with a page-footer reserve. Direction is fixed above the
    caret (never covers typed text), flipping below only when clipped.
    Junk below #12 (策是/測是…) is the documented price; truths deeper
    than 16 stay out of reach by design.
    Update (measured, landed): per-reading entries 3 → full trie (daily
    chars buried by frequency become reachable — 鍵 sat at #22 under
    ㄐㄧㄢˋ, invisible to paging and learning alike). Decode walks 4 per
    node on multi-syllable spans (+20% latency: dada 32→39 ms, 26-syl
    71→86 ms; full walk measured 3x, rejected) and the full node on
    single-syllable spans (~0.3 ms, no lattice to explode), so ㄐㄧㄢˋ pages
    間建見件健漸監鍵… instead of repair junk; 12-point top-1 battery
    byte-identical. Segment lists: single-span cap 64 (homophone browser),
    multi-span 16; panel pages up to 64.
4. English switching: Shift-hold Latin appends inline and Shift+Space
   toggles exist; collect the exact broken cases (mode indicator? CapsLock?
   toggle state after commit?) before changing behavior.
5. Punctuation (v1+v2 landed + pin-continue): CJK table in `Sources/MistypeCore/Punctuation.swift`
   (，的那 Shift+`,`/`.`/`/`/`;`/`1`, 「」『』 on quote/bracket keys,
   、· on `\`, ； on Ctrl+`;`, —— on Shift+`-`). Zhuyin-position keys stay
   phonetic so syllable-initial ㄝㄡㄥㄤㄦ keep working; separators pin the
   current pick and continue (commit is Return's job); Cmd shortcuts never
   hijacked. Follow-up: … needs a conflict-free key (Option layer).
6. Seamless mixed input (v1 landed): backtick toggles a latin run — letters   append verbatim (`L:`-marked keys, case preserved), spaces stay inside
   multi-word runs (`` `hello world` ``), tones/punct/digits/Return end the
   run, one commit at the end. No Shift toggle, no pause:
   `` `hello world`su3cl3 `` → `hello world你好`. Guessing is impossible by
   construction (bare keys stay Zhuyin), so `hello`-as-keys still decodes
   Chinese — auto-detect with English scoring stays future work, as do
   digits-inside-latin.
7. Preferences (v1 landed): UserDefaults-backed `MistypePrefs`
   (fuzzyRepair / toneTolerance / candidateKeys-reserved), read live per
   keystroke, editable from the input-menu Preferences panel or
   `defaults write`. Strict tone = explicit tones must match exactly
   (toneless still decodes); fuzzy off = no edit rescue. Falsify by
   toggling mid-session: behavior changes on the next key, no relaunch.
   Jev prefs landed alongside (default off, offline baseline preserved):
   `jevEnabled` master switch, `jevRichContext` richer-context gate,
   `jevApiKey` gateway key (or AI_GATEWAY_API_KEY env), `jevModel`.
   The adapter threads `JevConfig.canAttempt` through every decode entry
   point with presence-only logging. (Correction 2026-09-27: a debounced
   remote Choice request DID ship behind that gate and moves the highlight
   when enabled with a key — the triage verdict covered panel auto-hide,
   not this path. It now waits for a settled run; see architecture step 5.)
8. Segment lock v1 + Rime alignment targets: RETIRED as Opt+Right (falsified
   in the file trace: toneless input beeped, fully toned input committed
   exactly like Return — the only case it served was toned-head plus
   pending-tail). Replaced by the syllable cursor: plain Left/Right walk
   back over the converted span, the panel shows that word's options,
   Tab/digit/click/Return pin the pick (session-only, never disk) and move
   on; any edit returns to end, Return still commits once. Rime alignment
   so far: offline-first ✓, candidateKeys pref stored ✓, segmented lock-in
   via pins ✓ (soft — no early partial insertText yet); per-segment paging
   + span cursor beyond the pure-run gate stay future (the cursor needs a
   fully-resolved top-1 — repaired welcome, raw fallback out — with
   validated alignment; mixed/space-separated spans keep
   whole-span paging).
9. Cursor selection v2 (2026-09-27, `tools/cursor_replay.py`, 21 synthetic
   sentences x toned/toneless, real 112k lexicon). Hypothesis: listing every
   word that covers the cursor (McBopomofo-style, longest first) reaches the
   expected text more often than the aligned-word list. Three findings:
   (a) the cursor was dead on toneless input — the IME rebuilt syllables
   from the composition, where a space-terminated toneless run is ONE fused
   syllable, so the length check rejected every such sentence and Left only
   beeped; candidates now carry their decoded `syllables`. (b) Decoder bug:
   `repairComplete` emitted tail lengths shortest-first, so a one-symbol
   tail (ㄟ 欸) filled the caller's top-6 and the real final syllable was
   never decoded (大都欸, 作一誒, 很主恩, 不錯喔, 體議案, 中一奧); round-robin
   by tail length fixed toneless top-1 8/21 -> 12/21 with keynoise (27 rows)
   and the LM fixtures unchanged except 大都欸 -> 大對. (c) Covering options
   reach 21/21 in both styles vs 19/21 toned / 20/21 toneless for the
   aligned list (做作業, 已經寄出 need a different boundary), at a cost:
   worst list position 12–13 vs 5–10 (one case per style on page 2; score
   ordering was far worse, per-syllable ordering a wash). Picks now keep
   earlier picks outside the new span (`UserLexicon.pin(_:over:)`): without
   that, 錢包 after 帶錢 reverted 帶 -> 大 and the two pins cycled. Words
   stay inside their Zhuyin run (`run(containing:)`). Manual IME check
   pending; the end-of-span panel still lists whole sentences.
   Follow-up: the set grew to dev 40 / holdout 40 (readings derived from
   the pinned lexicon; holdout is confirm-only). Reading-only session pins
   paid per occurrence, so one 吃 pick re-segmented 晚餐想吃什麼 into
   灣吃安詳吃什麼 and pinning 做 rewrote both ㄗㄨㄛ (做做業); pins are now
   positional (run + run-local offset + readings). Dev reachable 40/40 in
   both styles. Holdout, aligned -> covering: reachable 40/40 both, picks
   toned 12 -> 12 and toneless 27 -> 25, worst rank 7 -> 5 and 11 -> 6.
   Remaining top-1 misses are context homophones the unigram table cannot
   separate (再/在 x4, 帶/大, 吃/持, 老師/老實, 上線/上限, 月/說) plus
   first-tone losses under the weak space-tone policy (喝/和, 約/說, 交/教).
   Learning was inert for sentences: commit recorded whole-composition
   readings -> whole text, but decode boosts only dictionary words
   (測試一下會不會打對 learned x3 still decoded 大對; the word 打對 fixed it
   and generalized). Learning is now word-level (`learnedWords`: pinned 2+
   syllable picks, words changed by a sentence pick, one-word input).
   `cursor_replay.py --learning` (dev teaches a temp lexicon): dev top-1
   52 -> 67/80, dev picks 35 -> 17; holdout top-1 50 -> 53/80 with 0 lost.
   Single chars inside sentences stay unlearned (再/在 needs context keys).
   Space as strong first tone + live conversion (user decision: space means
   ˉ as in RIME/鼠鬚管, and continuous typing must not need space to
   convert). Toned top-1 dev 29 -> 32, holdout 29 -> 31, 0 lost (喝一杯,
   約在, 喝水, 老師說, 這張); toned picks dev 13 -> 8, worst rank 12 -> 4.
   Toneless is now typed without the trailing space and converts live:
   identical to the old space-to-convert results; keynoise unchanged.
   Context learning (user decision): single-char picks are stored as
   "previous word|readings" -> text and boost only after that word. With
   `--learning`: dev top-1 after teaching 67 -> 78/80 (words only vs words
   + context), dev picks after 17 -> 2; holdout 52 -> 55/80, 0 lost —
   context rules are specific, so they neither transfer nor harm. Store
   bumped to v2; v1 files (mostly inert whole sentences) load empty.

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
