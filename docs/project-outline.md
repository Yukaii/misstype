# Project outline

## Problem

Conventional touch keyboards make the user divide attention between composing and locating small, exact targets. Chinese input adds another interruption: choosing candidates while the thought is still forming. Misstype explores whether a forgiving split surface can preserve a user's learned hand motion and postpone linguistic decisions until a phrase is complete.

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

Finding (ChiaKey word bigram, 2026-09-27, `tools/bigram_eval.py` +
`tools/chiakey_export.py`, 40 dev + 40 holdout synthetic sentences from
`cursor_replay`, toned + toneless; baseline top-1 dev 56/80, holdout
55/80). Hypothesis: a word-level, Taiwan-corpus homophone bigram (ChiaKey
Lexicon 2026.09.3, previous-word -> current-word bonus) can replace Jev
for tie breaking where the char-level LCCC bigram failed. Results:
(a) ChiaKey's bigram table over our lexicon: clean/ODbL 0 flips at any
weight; full (CC BY-NC) at weight 3 +3/-0 (上線 after 還沒, 已經寄出).
Safe but nearly inert — rows exist only where they change a pick under
*ChiaKey's own* unigram, and most of our misses are single-char ties
(帶/代, 再/在, 做/作, 吃/持, 得/的) that their unigram already decides, so
no row covers them. (b) ChiaKey unigram replacing ours: +21/-21, net 0
(scale 1/3/6 all alike); with its bigram +25/-22. It fixes exactly those
function-word ties but breaks 他→她, 你→妳, 那→哪, 在→債/再, 時間→事件,
and the damage concentrates in toneless input (+13/-15 vs toned +8/-6):
KeyKey scores rank words *within* a reading, so they are not comparable
across tones, which toneless decoding needs. Decode ~2x slower (27 → 55
ms mean, bigger table). Verdict: no drop-in replacement for Jev; the
lever that transfers is the *data*, not the table — a per-reading
function-word tie fix on our unigram (the 帶/再/吃/得 class) and a
bigram layer calibrated against our own unigram with our own held-out
fix/steal gate. `ContextBigrams` stays as a nil-by-default seam
(`MISSTYPE_BIGRAM`/`MISSTYPE_LEXICON` dev-only env hooks, byte-identical
decode when unset); ChiaKey data stays in `~/.cache`, never committed
(full table is CC BY-NC; clean is ODbL, share-alike on derived DBs).

Follow-up (within-reading reorder, `chiakey_export.py --reorder`): keep
our lexicon and scores, only permute score values inside one exact
reading into ChiaKey's order, so cross-reading (toneless) comparisons
keep our scale. Single-syllable readings only: +6/-1 (dev +4/-1, holdout
+2/-0; 帶, 做, 門 fixed; 喝→呵 broken, ChiaKey margin 0.03). All readings:
+7/-3 — multi-syllable reorder adds 你的→妳的 and 會不會→會部會, so
it is worse. Adding the full bigram at weight 3 on top: +10/-3. The
single-syllable reorder flips top-1 on 276 of 1309 readings, and the
battery covers only a handful, so the flips need human review before
shipping. ChiaKey's margins are near ties (帶/代 0.01), so no margin gate
separates good flips from bad. Still open: accept or reject each flip,
and the license terms for shipping a derived order.

Shipped (curated order, `Resources/reading_order.tsv`): 276 flips
hand-reviewed for "which char is typed alone in Taiwan everyday
writing". 95 accepted (帶, 做, 門, 聊, 店, 記, 見, 住, 常, 話, 還, 睡, 認,
嗯, 嘛, 的 ㄉㄧˊ …), about 40 rejected (呵 over 喝, 宜 over 一, 甚 over 蛇,
中 over 重, 維 over 為, 各 over 個, 加 over 家, 劉 over 流 …), the rest
left alone as near ties or rare chars. `prepare_lexicon.py` swaps only
the reviewed pair's scores and fails on stale rows. Battery: +6/-0 (dev
56→60, holdout 55→57, i.e. 111→117/160), offline, decode latency
unchanged (dada ~50 ms, 26-syllable ~90 ms). The rows are our own
decisions (no ChiaKey scores copied); ChiaKey was only the source of
candidates. Toneless cross-reading misses (吃→持, 再→在) stay open;
they need context, not per-reading order.

Finding (toneless cross-tone order, NAER 通用詞頻表, 2026-09-27). After
the curated order, 38 of 43 battery misses have no ChiaKey bigram row
(so it is a data gap, not a trigger problem). Most are toneless
cross-tone picks (吃→持, 請→情, 貴→規, 嗎→馬, 找→照): McBopomofo's char
counts include bound morphemes (持 via 支持, 情 via 事情), so formal
chars beat standalone ones. NAER's word-frequency table counts segmented
tokens, so a single char's value is its standalone use (吃 931 vs 持 48
per million; CC BY 4.0). Falsified first: interpolating it into
unigrams. At 0.5 the gain nets ~0; single chars only at 0.9 gives +7/-4
(記得→及的, 吃辣→吃那: standalone chars outgrow words and the 5.0 repair
cost); all words at 0.9–0.99 also brings 週→周 variants. Scale changes
leak everywhere. Also falsified: a lexicon-wide slot permutation within a
toneless base. On a fresh set (400 Common Voice zh-TW sentences, CC0,
unrelated to tuning, 800 cases) it scored +32/-17, but toned was +15/-16
churn, because it rewrote each char's own-reading score. Shipped:
the same permutation as a *toneless-only* override (`toneless.tsv`, 4,616
chars). It is read only for a one-syllable span typed without a tone, so
toned input is untouched by construction. Common Voice: 459→475/800,
+17/-1 (toned 0/0). Battery: 117→122/160, +6/-1. Both breaks are word
vs char segmentation (這件事|請, 刷|處) that the old order hid by
accident. Offline; latency unchanged (dada 51 vs 52 ms, 26-syllable 93
vs 95 ms, sequential). `tools/bigram_eval.py --set cv` is the new
held-out gate (sentences stay in `~/.cache`).

Finding (word vs char segmentation, per-word cost, 2026-09-27). Of 325
Common Voice misses, 179 are segmentation errors, mostly a dictionary
word losing to a split into common chars (面試→面是, 各式→個是,
進程→近成, 成見→成件). Scores explain it: relative to NAER's token
counts, McBopomofo single chars are about 1.26 too high and words about 0.48
too low (medians over 5.6k chars and 63k words). So each extra token is
over-rewarded by about 1.7 (面試 -11.9 vs 面+是 -11.1; NAER -11.3 vs -13.1).
Fix: the classic word insertion penalty, a constant cost per dictionary
word on a path (`LexiconDecoder.wordPenalty`; `LexiconLoader` sets 0.5;
core default 0 keeps fixtures identical). Sweep on Common Voice (800):
0.5 +18/-3, 1.0 +25/-11, 1.5 +33/-15, 2 +33/-17, 3 +37/-22. Larger
values fix more words but merge toneless coincidences faster (想吃→相持,
在找→在朝, 弟弟→低低: under toneless input any tone forms a word).
Synthetic battery at 0.5: +1/-2. Shipped 0.5, net +14 over 960 cases,
latency unchanged. Deliberately not tuned further (e.g. a separate
toneless value): both sets are too small to tune on without overfitting.
Remaining: words that need >= 1.0 (面試), and context-bound picks
(再/在, 得/的, 打對).

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
Measure with: `MisstypeIME --decode "<keys>" --user-lexicon <path>`.

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
    list, footer shows `n / m`. Update (landed): Left/Right never page (they
    move the syllable cursor); PageUp/PageDown, and `-`/`=` while in
    selection mode, flip a page keeping the row (clamped, wrapping at the
    ends). Manual check pending: Fn+↑/↓ on laptop keyboards.
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
4. English switching: a lone Shift tap mid-composition now opens/closes a latin run
   instead of committing (2026-09-29; manual check pending). Shift-hold Latin appends inline and Shift+Space
   toggles exist; collect the exact broken cases (mode indicator? CapsLock?
   toggle state after commit?) before changing behavior.
5. Punctuation (v1+v2 landed + pin-continue): CJK table in `Sources/MisstypeCore/Punctuation.swift`
   (，的那 Shift+`,`/`.`/`/`/`;`/`1`, 「」『』 on quote/bracket keys,
   、· on `\`, ； on Ctrl+`;`, —— on Shift+`-`). Zhuyin-position keys stay
   phonetic so syllable-initial ㄝㄡㄥㄤㄦ keep working; separators pin the
   current pick and continue (commit is Return's job); Cmd shortcuts never
   hijacked. Follow-up: … needs a conflict-free key (Option layer).
6. Seamless mixed input (v1 landed): backtick toggles a latin run — letters   append verbatim (`L:`-marked keys, case preserved), spaces stay inside
   multi-word runs (`` `hello world` ``), punct/Return end the run (digits stay
   in it since 2026-10-04; see the bug note below), one commit at the end. No Shift toggle, no pause:
   `` `hello world`su3cl3 `` → `hello world你好`. Guessing is impossible by
   construction (bare keys stay Zhuyin), so `hello`-as-keys still decodes
   Chinese — auto-detect with English scoring: measured v1 in `MisstypeCore`
   (`decodeMixed`, see "Mixed Chinese/English without a switch" below), not
   yet wired to `InputSession`; digits-inside-latin stays future work.
7. Preferences (v1 landed): UserDefaults-backed `MisstypePrefs`
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

Live-conversion stability (2026-09-27, user report after install: already
converted characters fell back to Bopomofo). `tools/live_trace.py` replays
each synthetic sentence key by key through `--live-trace` (the IME's
`livePreview`) and counts reverts (Han -> Bopomofo) and churn (a settled Han
char changes). Clean typing never reverted; the cause was a tone key or
Space closing a run whose last syllable is invalid (眼睛 + ㄐ + Space):
`repairComplete` found no valid tail and the whole run fell back to one
unresolved reading (ㄧㄢㄐㄧㄥㄐ). The clean lead now converts and only the
invalid tail goes to decode (repaired if possible, else raw); runs of <= 4
keys keep their whole-syllable repair. Replay unchanged, keynoise one row
better (swap CER 1.067 -> 0.933). Remaining: churn 38/1738 keystrokes
toned, 78/1168 toneless (e.g. 我進體 -> 我今天).

Settling accepted text (2026-09-27, user report: long input listed
sentence alternatives that only varied old text before a ，, while the
part being typed was cut off). Earlier runs, and words ending 3+
syllables before the end of the run being typed, settle automatically:
character-level pins (word-level ones froze 這 as a one-char word and
blocked the later merge into 這部 -> 這不電影), kept apart from explicit
picks (never learned; explicit picks override them per run), and
candidates that break a pin drop out of the list. `live_trace.py
--settle K`: K=1 wrecks accuracy (toneless final dev 23 -> 8); K=2 loses
one holdout sentence; K=3 keeps dev identical, holdout toned 31 = 31,
toneless 21 -> 22, and 4-sentence ，-joined inputs identical. Panel
windows longer than a row now keep the end nearest the cursor.

Heterophone weighting (2026-09-27, user report: typed ㄗㄢˋ, got 暫):
not a fuzzy slip — BPMFBase lists 暫 under both ㄓㄢˋ and the variant
ㄗㄢˋ, and `prepare_lexicon.py` gave every reading the char's whole
count. It now ports McBopomofo cook.py: heterophony1 keeps the count,
heterophony2/3 drop 0.693 log10 per rank, unlisted readings sit at the
-6.8 log10 floor (618 entries move; 長 ㄓㄤˇ alone relies on phrases like
成長). Replay, no sentence lost: toned top-1 dev 32 -> 33, holdout
31 -> 33 (散步, 下個月, 吃辣 fixed); toneless dev 23 = 23, holdout
21 -> 22. ㄗㄢˋ now lists 贊 讚 暫 (贊/讚 0.29 apart; learning settles it).
Shift+Return commits the keys as typed, for 注音文 made of valid
syllables (a lone ㄗ decodes to 資).

Long-composition latency and chunked auto-commit (2026-09-29, user report:
the UI gets laggy as a composition grows, and Backspace sometimes eats a
whole run). Cause: `livePreview` re-decodes the entire composition on every
key, so cost grows with length; profiling put it in Swift's Unicode-
normalizing String ==/< on long sentence text inside the beam's `add` and in
O(n) `utf16.count` calls. Two changes. (1) Output-identical decoder speedup
(240 replay cases byte-identical): reject hopeless candidates by score before
building them, compare text as UTF-8 bytes, cache prefix lengths — toned 250
keys 155 -> 48 ms per key, toneless 160 keys 1060 -> 380 ms. (2) Chunked
auto-commit: past 24 syllables the settled head commits in whole-word chunks
while the last 12 keep composing (`tools/session_latency.py`, 12 sentences as
one composition, real lexicon): final text unchanged, toned mean 17.2 -> 4.0
ms (p95 53 -> 9), toneless mean 169 -> 46 ms (p95 418 -> 83, max 548 -> 107).
Backspace: toneless words typed continuously fuse into one body when a single
tone or Space finally closes them, and Backspace removed the whole body; it
now removes one decoded syllable. Limits: auto-commit waits while an explicit
pick, pin, cursor or open list exists (their learning would otherwise be
lost) and while the head has repairs or unresolved syllables; a committed
chunk can no longer be revised by the IME (Backspace past the tail deletes
it in the app). Manual check pending: chunk boundaries in real apps (marked
text redraw), feel of the 24-syllable default, and whether it needs a
Preferences control.

Smart quotes, symbol menu, modern vocabulary (2026-09-29, user request).
`'` now pairs itself inside the composition (「 opens, 」 closes while one is
unclosed; Shift+`'` does the same for 『』; `[` `]` still type 『 』 directly).
Only the composition is inspected, so a 「 already committed to the app is
not seen. Symbol menu: typing a mark opens the candidate list with its group
(`Punctuation.groups`: ，、；：, 。．…, quotes and brackets as separate open
and close groups so a swap never flips direction, dashes, dots, and one
group per Shift-row symbol — currency, math, ※★ …). The typed mark is row 1;
Tab/Up/Down swap it live and arm the selection keys, which pick; Esc keeps
what shows; any other key accepts it and acts normally; panel click picks.
`…` now has a home (the period group). No ASCII choices: they would collide
with physical key labels in the raw key stream. Manual check pending: panel
noise after every comma, and whether Up/Down should open the menu without
Tab. Lexicon: 預設 already ranked first alone; a 86-word modern probe list
found 14 missing words (貼文, 預覽, 截圖, 資料夾, 表單, 推播, 貼圖, 迷因, 按讚,
轉貼, 外送, 掃碼, 行動支付, 表情符號), now in `local_phrases.tsv`; the 240
replay cases are byte-identical. Same-reading rivals still lose as rank 2
(克服/客服, 便是/辨識, 城市/程式, 藍芽/藍牙, and toneless 同志/通知, 短線/斷線,
癌症/驗證) — real homophone ties for learning, not a scoring bug.

Learned single characters leaked into sentences (2026-09-29, user report:
預設 came out as 育設 / 與設文字). Reproduced with the user's own store
(`--decode --user-lexicon`): a single earlier pick `ㄕㄜ -> 設` (+6) outweighed
the word 預設 (about 3 points ahead), because word-level learning keys
toneless-joined readings and applied to every span of that reading. Sentence
single chars are meant to be learned by context rules only (下次|ㄗㄞ -> 再).
Fix: a learned one-syllable bonus is paid only when the whole input is that
one syllable. Both reports decode 預設 again; the learning battery
(`cursor_replay.py --learning`) is unchanged: dev top-1 63 -> 79/80, picks
19 -> 1, holdout 58 -> 61, 0 lost. Regression test:
`testLearnedSingleCharDoesNotBeatAWordInsideASentence`. Side effect to watch:
a user who only ever types one character and wants it learned inside longer
input must rely on context rules, which need a preceding word.

## Next steps (queued 2026-10-02)

State: the macOS Zhuyin IME is close to daily use and the Linux fcitx5 port
passes the same conformance scenarios (C1–C13). Open work, in the order it
should be taken:

1. **Linux desktop acceptance (L6).** Type in a real fcitx5 session (docs/
   linux-port.md). The headless suite cannot see client-side problems such as
   marked-text styling (the macOS caret bug was exactly that). Done when the
   L6 checklist passes on one X11/Wayland desktop.
2. **Port touch/spatial fuzzy decoding to `MisstypeCore`.** *(v1 and
   the lattice version landed 2026-10-04, see "Touch fuzzy port" below; open:
   wiring into `InputSession`/a touch surface, fixed-cost floor.)* Coordinate-aware neighbor hypotheses from raw `(x, y)`, the
   versioned `full-split-1` layout and the `tools/noise.py` jitter measurements
   started in `src/misstype` (M2/M3); the layout, mapper and a beam-based
   `decodeTouch` now live in `Sources/MisstypeCore/Touch.swift`.
3. **Measure against a conventional keyboard.** *(Break-even target computed
   2026-10-04, see "Keyboard comparison" above: taps must spread within
   ~0.07-0.10; the human tap-spread measurement is what is missing.)* The gate in AGENTS.md for any
   hardware work: task completion time, backspaces, interruptions (see
   Measures), on the Swift decoder.
4. **Linux user-dictionary editor.** The file is plain text; a `misstype-dict`
   command (list / add / remove) or an fcitx5 config page. Low risk.
5. **Personalization from use.** *(Keyboard half started 2026-10-06: the
   decoder takes per-user substitution costs, learned from Backspace re-types,
   picks and reverts. The replay beats generic on unseen sentences; it is off
   by default and the adapters are not wired. See "Personal channel model"
   below.)* Per-key tap
   distributions learned from confirmed taps (a 2-D Gaussian per key replaces
   the fixed `1 - 1.5d` weight), then per-user repair costs from Backspace
   re-types. Labels come only from explicit signals (Backspace re-type, an
   explicit pick), with decay and a cap like `UserLexicon`'s +10; falsify on a
   synthetic user with a fixed tap offset, replayed offline. Parameters stay
   local, exportable and clearable. Needs the touch baseline below first.
6. **Pairing / calibration onboarding (idea, deferred by the user
   2026-10-04).** A first-run flow that has the user tap a few known targets
   to fit their key offsets and hand position before typing. Do it when custom
   hardware pairing is actually being built; it is the natural seed for the
   per-key distributions in item 5.
7. **Hide gesture for the user dictionary** (only if wanted): a key on the
   highlighted candidate that writes a `!` exclusion line. The file format and
   decoder already support exclusions; only the gesture is missing.

**Parked: porting the core to Rust (decision 2026-10-02: stay on Swift for
now).** Revisit when a target Swift serves badly is real — web (wasm),
Android, Windows, or a mobile keyboard with a tight memory limit — or when the
~71 MB static Foundation in `libMisstypeCAPI.so` hurts distribution. Go was
rejected (runtime and GC inside IME/mobile processes; the gain over Swift is
mostly a size win, not speed). Zig is the lightweight alternative (tiny
toolchain, fast builds, native C ABI) but pre-1.0. Notes for whoever does it:
- Cheap checks first, in Swift: drop full Foundation from `MisstypeCore`
  (`FoundationEssentials`) and re-measure the Linux library size; profile
  `tools/bench.py` / `tools/session_latency.py` (p95 for a 25-syllable
  sentence) before blaming the language.
- Smallest experiment: port only the decoder (trie, `decode`,
  `decodeComposition`, `decodeSegments`) plus the `CoreTests` that exercise it,
  run on the real lexicon; require identical top candidates on the fixtures
  and a clear latency win before porting `InputSession`.
- The contract that makes a port safe already exists: the C ABI
  (`misstype.h`) and conformance scenarios C1–C13 are language-neutral, and
  the fcitx5 addon would not change. Alignment, caret and mark ranges are
  UTF-16 offsets (macOS marked text), so a UTF-8 language needs explicit
  conversion at those points.
- Web would ship as wasm in a Web Worker with a prebuilt binary trie instead
  of `lexicon.tsv` (cached in IndexedDB); the touch prototype is the natural
  first web surface since it needs raw `(x, y)`. Do the touch-fuzzy port
  (step 2) in whichever language the decoder will live in, to avoid porting it
  twice.

Done and recorded: user dictionary and its Linux parity (architecture.md,
decode policy 9), styled marked text for IMK (the candidate window shows rows
only; AGENTS.md).

### Touch fuzzy port (2026-10-04)

`TouchLayout` (`full-split-1`, same table as `touch.py`), `TouchMapper`
(distance-ranked neighbors, weight `max(0.1, 1 - 1.5d)`) and
`LexiconDecoder.decodeTouch` landed in `MisstypeCore`. Mapper parity with Python
is locked by golden values from `nearest_key` (`TouchTests`); the recorded
`touch-*.jsonl` fixtures replay to the same keys and decode to 你好 / 早上好.
Design: a beam of at most 16 key sequences per phrase, each charged
`spatialScale x (d - d_nearest)` per non-nearest tap, each decoded through the
shipping `decodeSegments`; a tone tap stays exact and tone keys are never
substitutes for Zhuyin taps (Python parity, an open lever).

Measurement (`TouchNoiseSweepTests`, real McBopomofo lexicon, seeded
uniform-disk jitter, top-1 exact match). Arms: A nearest key; B nearest key +
today's keyboard edit repair; D spatial hypotheses + repair. 30-50 seeds/cell,
spatialScale 10:

| probe (taps) | r | A | B (today) | D (spatial) |
|---|---|---|---|---|
| ni-hao (6) | 0.08 | 70% | 77% | 93% |
| ni-hao | 0.10 | 33% | 47% | 82% |
| zao-shang-hao (9) | 0.10 | 20% | 37% | 80% |
| wo-shi-xue-sheng (11) | 0.08 | 57% | 67% | 97% |
| wo-shi-xue-sheng | 0.10 | 10% | 20% | 57% (80% at beam 64) |
| dada (29) | 0.08 | 33% | 50% | 77% |
| dada | 0.10 | 0% | 3% | 20% |

Findings. (1) Hypothesis holds in the 0.08-0.12 band: spatial hypotheses beat
the keyboard repair that ships today by +15 to +45 pp and exact input is
untouched (r = 0: D equals B on 120/120 and 200/200 traces). Python's absolute
rates are not comparable: its decoder is a 9-phrase fixture table, the Swift
decoder is open-vocabulary over 112k entries, so the right reference is B.
(2) `spatialScale` wants to be small (5 = 10 > 20 > 40 > 80): distance should
only break near-ties, the language score carries the rest. (3) The beam is the
limit on long phrases and does not scale: beam 64 lifts wo-shi-xue-sheng r=0.10
57% -> 80% at ~4x latency, beam 256 83% at ~17x. Release-build latency at beam
16 is 4-23 ms for 6-11 taps at r <= 0.10 but 99 ms for the 29-tap sentence, so
the next step is not a wider beam but putting the per-tap costs inside the
decoder's per-syllable alternatives (lattice) instead of enumerating key
sequences. r >= 0.15 stays out of reach, as in the Python sweep.
#### Lattice integration (same day)

`decodeTouch` now prices spatial hypotheses inside each syllable's reading
options (a slice of n taps offers the readings of its 24 cheapest key
combinations; edit repair also runs on the 4 cheapest, in a second pass that
fires only when the first leaves repairs or unresolved text) and lets the
decoder's own beam weigh them. The beam version stays as `decodeTouchBeam` for
comparison. Top-1, 30 seeds/cell, release build, scale 10, real lexicon
(`Lat+R` is the default; its first version did not repair spatial combos and
lost short phrases whose tone tap landed on a Zhuyin key, which needs one
swap AND one deletion in the same slice):

| probe (taps) | r | B (today) | Beam | Lattice | Beam ms | Lattice ms |
|---|---|---|---|---|---|---|
| ni-hao (6) | 0.10 | 47% | 83% | 80% | 7 | 6 |
| ni-hao | 0.15 | 20% | 67% | 53% | 47 | 9 |
| zao-shang-hao (9) | 0.12 | 13% | 47% | 53% | 32 | 14 |
| zao-shang-hao | 0.15 | 7% | 20% | 33% | 35 | 16 |
| wo-shi-xue-sheng (11) | 0.10 | 23% | 57% | 87% | 48 | 32 |
| wo-shi-xue-sheng | 0.12 | 7% | 33% | 73% | 80 | 37 |
| wo-shi-xue-sheng | 0.15 | 0% | 10% | 47% | 115 | 40 |
| dada (29) | 0.10 | 3% | 20% | 37% | 100 | 86 |
| dada | 0.12 | 0% | 0% | 13% | 132 | 90 |

Findings. (1) The lattice wins from ~10 taps up (+30 to +40 pp over the beam,
+50 to +65 over today's keyboard repair) at lower latency, and exact input is
still untouched (r = 0: identical to B on 120/120 traces). (2) On 6-tap
phrases the beam is up to 14 pp better at r = 0.15 (small cells: 30 seeds, so
4 traces); repair on 8 combos recovers 7 of them but costs latency and hurts
the 29-tap probe, so the default stays 4. (3) Cost has a fixed floor: the
29-tap sentence takes 35 ms at r = 0 (beam: 20 ms) because every slice prices
24 combinations even when the taps are exact. Cheap next lever: skip spatial
combos when the nearest-key reading is clean and the tap is well inside its
key. (4) 29 taps at r >= 0.12 is still out of reach; that is a limit of the
evidence (each tap is 1 of ~5 keys, errors compound), not of the search.
Run: `MISSTYPE_TOUCH_SWEEP=1 swift test -c release -Xswiftc -enable-testing
--filter TouchNoiseSweepTests` (needs `python3 script/prepare_lexicon.py`
first; knobs in the test's header comment).

#### Keyboard comparison: break-even target (2026-10-04, no human data)

The AGENTS.md gate needs human measurements (completion time, backspaces,
interruptions) that do not exist yet. What can be computed now is the target a
real measurement has to hit: `TouchNoiseSweepTests.testBreakEven` compares a
physical-keyboard typist (each Zhuyin key slips to its nearest neighbor with
probability p, decoded as today with edit repair) against a touch typist (tap
spread r, lattice decoder). Mean sentence top-1 over the four probes, 40 seeds:

| touch + lattice, tap spread r | 0.04 | 0.06 | 0.08 | 0.10 | 0.12 | 0.14 |
|---|---|---|---|---|---|---|
| sentence top-1 | 100% | 99% | 84% | 68% | 53% | 38% |

| keyboard + repair, slip rate p | 1% | 2% | 4% | 8% |
|---|---|---|---|---|
| sentence top-1 | 94% | 89% | 82% | 71% |

Reading: touch matches a 4%-slip keyboard at r ~ 0.08, an 8%-slip one at
r ~ 0.10, and a careful 1%-slip typist (94%) at r ~ 0.07. So the touch surface
is competitive on decoded accuracy only if real taps spread within roughly
0.07-0.10 of the key centre (normalized units, uniform-disk model); at 0.12
and above it loses to a mediocre keyboard even with the lattice. Caveats: the
keyboard model has only neighbor slips (no transposition or omission, which
the keyboard repair also handles, so it flatters neither side), taps are
isotropic in normalized units while a real surface is not square (on a
10 x 7 cm pad, r = 0.08 is ~6 mm vertically), and accuracy is only one of the
three gate measures: speed and interruptions are untouched by this.

Real measurement protocol (needs no personal text, ~2 minutes per person):
show a known target key, record the tap `(x, y)` with the target key id,
repeat each of the 41 keys a few times on each surface, then report per
person the RMS and 95th-percentile distance from the key centre in normalized
units and in millimetres. Compare with the 0.07-0.10 band above. The same
trace is the seed for per-key tap distributions and for a pairing /
calibration onboarding (next-steps items 5 and 6).

### Mixed Chinese/English without a switch (2026-10-04)

Question: can bare keys be read as English when that is clearly what was
typed, with typo repair, without hurting Chinese? Source of English words:
hermitdave/FrequencyWords `en_50k` (2018, pinned, checksum-verified; CC BY-SA
4.0 content, licence note in `third_party/FrequencyWords/LICENSE.md`; picked
over the Google 10k list because that one carries LDC research-only terms,
and over SCOWL because SCOWL has no counts and needs a build). 46,717
lowercase a-z words after filtering; `script/prepare_lexicon.py` writes
`.cache/frequencywords/english.tsv` (never committed).

Design (`Sources/MisstypeCore/MixedDecode.swift`): candidate English spans are
substrings (>= 3 letters) of consecutive letter keys that spell a word, or
sit one edit (substitution, insertion, deletion, adjacent swap) from a word
of >= 5 letters (symmetric-delete index). Every non-overlapping subset of up
to 3 spans, including none, is decoded through the shipping `decodeSegments`
(latin runs already split Zhuyin runs there) and priced
`word ln p - 6 x edits - switchPenalty`; the best total wins, so the English
reading must beat the Chinese reading of the same keys on score. Bare keys
stay Zhuyin by default.

Measurement (`MixedSweepTests`, real lexicons; 200 mixed inputs = Chinese
piece + English word + Chinese piece, 600 pure-Chinese inputs of 3-6 lexicon
words, 150 typo'd words; toned / toneless typing):

| switch penalty | mixed top-1 | pure Chinese falsely switched | typo'd English top-1, fuzzy on | fuzzy off |
|---|---|---|---|---|
| 0 | 100% / 96% | 0% / 1% | 78% / 75% | 0% / 0% |
| 2 | 100% / 96% | 0% / 0% | 80% / 78% | 0% / 0% |
| **4 (default)** | 100% / 96% | 0% / 0% | 80% / 78% | 0% / 0% |
| 6 | 92% / 90% | 0% / 0% | 80% / 78% | 0% / 0% |
| 8 | 92% / 90% | 0% / 0% | 80% / 76% | 0% / 0% |

Findings. (1) Yes, offline: no false switches in 600 pure-Chinese inputs from 2
up, clean English words are found 100% / 96%, and one-letter typos are
repaired 80% / 78% (nothing without the fuzzy layer). (2) The collision risk
the design feared (short words such as the / you / for) did not show up:
English words rarely spell valid Chinese key runs, because Zhuyin runs are
syllable-shaped (initial + final) while English letter runs are not. (3) The
cost is latency: `decodeMixed` takes 48 ms vs 18 ms for a plain decode of the
same mixed input (release build), plus 350 ms once to build the index for
46k words. Fine for a finished phrase; running it per keystroke needs pruning
first (only when a letter run of >= 3 keys exists, cache spans per key
prefix). (4) Limits of the evidence: the negatives are random lexicon-word
sequences, not real prose; the positives use 18 words and 5 Chinese pieces;
typos are one slip in words of 6+ letters; the 20% typo misses and the 4%
toneless misses are not yet classified; no uppercase, digits, or hyphenated
words. Treat it as a validated mechanism, not a quality claim.

#### Wired into `InputSession` (same day)

`InputSession.refresh` now runs `applyEnglish` after the live preview: the
English reading is inserted as the top candidate when it beats the Chinese one
by 3 points on top of the switch penalty (`MixedDecoding.autoMargin`), listed
second when within 8 below it (`suggestWindow`), and absent otherwise. The
word list loads off-thread (`InputEngine.loadEnglishLexicon`, ~330 ms index)
from `english.tsv` beside the lexicon; no file, no change. Setting:
`SessionSettings.mixedEnglish` (core/Linux default on when the file exists,
macOS `MisstypeMixedEnglish` default **off**, Settings toggle "Recognize English
words while typing"). Bare Zhuyin/tone/space keys only: once a latin run or
punctuation is in the composition the pass stays out. English readings are
"complete" candidates (`completeTexts`): they show no raw tail and are kept
out of settled/positional pins, the syllable cursor, chunked auto-commit and
learning, because their run indexes do not match the composition's own.

Measured on the shipping path (`testSessionPath`: live preview +
`applyEnglish`, real lexicons, 200 mixed / 200 typo'd / 600 pure-Chinese
inputs, toned / toneless):

| | top-1 | in top 4 | adopted automatically |
|---|---|---|---|
| clean English | 92% / 90% | 100% / 99% | 92% / 92% |
| one-letter typo | 80% / 77% | 86% / 82% | 95% / 97% |
| pure Chinese | - | - | **0% / 0%** (English *suggested* in 0.7% / 4.7%) |

Two things this run corrected. A first gate that only ran the pass when the
Chinese reading showed trouble (repairs, unresolved text, raw tail) lost 18
points of recall (clean English 82% / 80%) because words like you / for spell
valid Chinese syllable pairs, so it was dropped. Span-level pruning replaced
it: each span is scored alone against the Chinese reading and only survivors
are combined, and the plain Chinese score is computed once.

Cost, release build, per live refresh: toned inputs 7-10 ms vs 1 ms without the
pass; toneless mixed inputs 111-134 ms vs 34-44 ms, i.e. a visible hiccup per
keystroke while an English span is in the composition. That is why the macOS
default is off. Pure Chinese costs 2-11 ms (a span scan). Worth doing before
turning it on by default: reuse hypotheses across keystrokes (the composition
grows by one key), and run the pass off the main thread.

Not done: a Linux conformance scenario (the C1-C13 harness has no word list
installed, so the fcitx5 suite is unaffected; coverage is `MixedSessionTests`);
real-typing quality, which needs actual mixed text typed by a person.

Run: `MISSTYPE_MIXED_SWEEP=1 swift test -c release -Xswiftc -enable-testing
--filter MixedSweepTests` after `python3 script/prepare_lexicon.py`.

### Digits inside a latin run (2026-10-04, user-reported bug)

After English was started with a lone Shift tap (or the backtick), the number
row still produced Zhuyin: `abc123` became `abcㄅㄉˇ`, because a digit ended the
run and 3/4/6/7 are tone keys. Digits are now literal text inside a latin run
(`KeyEvent.Key.digitLabel`, `Composition.appendLatin` accepts ASCII digits);
Shift+digit stays the full-width symbol layer. Behavior change: a tone key can
no longer be used to drop back to Zhuyin from a latin run; the toggle that
opened it (backtick, lone Shift tap) closes it, and punctuation still ends it.
Global 中/英 mode was never affected in the core (digits pass through,
`LatinDigitTests`); if the number row misbehaves there on macOS the cause is
in the IMK adapter or the client app, not the session.
Tests: `LatinDigitTests` (incl. the Shift-tap case), `testBacktickLatinRun`.

### English reverted to Zhuyin text after the next key (2026-10-04, user-reported)

Reproduced with a per-key preedit trace on the real lexicons. Three causes,
all in the first wiring of the mixed pass:

1. **Punctuation.** `applyEnglish` required the composition to be bare
   Zhuyin/tone/space keys, so the moment a punctuation literal (Shift+`,` ->
   ，) joined it the whole English reading vanished and the letters went back
   to being Zhuyin: `你好python` -> `你好嗯支持次欸四，`. The pass now carries
   punctuation, earlier latin keys and spaces through unchanged.
2. **Capitalized words.** `Python` typed as Shift+p then `ython` is one latin
   key plus bare keys, never matched (`你好P字垂死`). A span may now start with
   leading latin keys, provided at least one key is bare; the capital is kept.
3. **The key just typed disappeared.** The live preview left the
   syllable being typed raw, the mixed text did not, and fuzzy matching read
   `pythonv` as a typo of `python`, swallowing the `v` of the next Chinese
   syllable. Mixed readings now show the raw tail (and commit it), and a
   different extra letter after a whole word is no longer a typo (a doubled
   one, `pythonn`, still is). Scoring moved to the live-preview basis too: each key left
   raw costs `MixedDecoding.rawKeyCost` (5), otherwise an unresolved tail was
   charged to both readings and cancelled the English advantage.

Shipping-path numbers did not change (clean English 92% / 90% adopted, pure
Chinese 0% adopted), refresh cost fell slightly (95 vs 111 ms toneless).
Tests: `MixedSessionTests` (punctuation then more Chinese, capital, raw tail).

### Personal channel model (2026-10-06)

A noisy-channel decoder has two halves: the language model (is this text
likely) and the channel model (how does this person mistype). Learning
(`UserLexicon`) and the user dictionary personalize only the first. The repair
tiers price every user the same: a phonetic confusion such as ㄣ/ㄥ costs 5.0,
which in our natural-log units means a slip rate of about e^-5, or 0.7%.

Hypothesis: for a user who systematically types ㄥ for ㄣ, a cheaper personal
ㄥ→ㄣ repair recovers their slips without flipping genuine ㄥ input. It is
falsified if no cost gains more than it loses.

Mechanism: `ChannelModel` (typed key → intended key → cost), set as
`LexiconDecoder.channel`, follows the same overlay contract as
`contextBigrams`. nil (the default) gives byte-identical decode. A personal pair
replaces the generic cost for that pair only. It is directional, rides along
with every syllable like the phonetic confusions, and is clamped at
`ChannelModel.floor` (0.5) so exact input always keeps a margin. Nothing sets
it yet.

Oracle sweep (`ChannelSweepTests`, real lexicon): the synthetic user types
every ㄣ as ㄥ. Probes are the most frequent reading per side (300) and the 80
`cursor_replay` sentences. Only probes whose exact typing already decodes
top-1 are counted. "Recovered" is the share of slipped ㄣ probes decoded
right; "kept" is the share of exact ㄥ probes still right.

| group, mode | generic 5.0 recovered | at 2.3 | at 1.2 | kept at 1.2 |
|---|---|---|---|---|
| words 2-4, toned | 65.7% | 96.3% | 99.0% | 100% |
| words 2-4, toneless | 49.8% | 85.1% | 95.9% | 100% |
| sentences, toned | 83.9% | 96.8% | 96.8% | 100% |
| sentences, toneless | 59.1% | 81.8% | 90.9% | 100% |
| single chars, toned | 8.8% | 22.0% | 42.9% | 86.5% |
| single chars, toneless | 0% | 21.1% | 36.8% | 76.2% |

Not falsified wherever there is context. In words and sentences the pair
recovers most slips and no exact ㄥ probe flipped at any cost down to 0.5. A
lone character is a real trade-off with nothing to break the tie: at 1.2,
仍→人, 風→分, 寧→您 and so on flip. There the right cost depends on how often
this user actually slips, which is the reason to learn the cost rather than
fix it. Read as a log-odds, a 10% slip rate is cost ~2.3 and 30% is ~1.2.
Latency: toned decoding is unchanged; toneless sentences go from 13.9 to about
17 ms per decode at 1.2, because more repaired paths survive the beam.

Learning half (landed 2026-10-06, off by default). This is two learners adapting to each
other: the system adapts to the user, and the user adapts to the system's
habits. The rule is that the system follows the user, but more slowly than the
user changes (user decision 2026-10-06).

- Estimate: a pair's cost is -ln(slips / opportunities), smoothed toward the
  generic 5.0 and clamped to [learned floor, 5]. Opportunities come from
  committed syllables.
- Time decay: counts are exponentially decayed (a half-life in typed
  syllables, not wall time). A habit the user has dropped therefore fades
  back to the generic cost instead of "correcting" input that is now right.
- Signal weights. The strongest signal is a reverted repair: the user picks
  the exact-reading text over a repair the system made (typed ㄕㄥ, got 深,
  picked 升). It means the system over-corrected, so it is weighted well
  above one observation, against the slip side. A Backspace re-type of one
  key inside a syllable counts as one slip. A repaired commit that is never
  reverted counts only weakly, because it may simply be unnoticed.
- Degenerate loop (sloppier typing → looser costs → sloppier typing):
  learned costs never go below a learned floor of 1.2, about a 30% slip rate,
  which is above the decoder's 0.5. Exact input therefore always stays
  stronger evidence than a learned habit, and the user keeps the ability to
  type precisely as a fallback. This is a default to revisit with real data.
- Stability: costs move by a bounded step and only between compositions,
  never mid-typing, so a frequent word's top-1 does not jump under the
  user's compensating habits.

Implementation: `ChannelLearner` in `ChannelModel.swift`, owned by
`InputEngine` (`channelLearner`, persisted at `channelLearnerURL`, nil = memory
only). It is on only when both `SessionSettings.channelLearning` (default
off) and `userLearning` are on; off means the decoder overlay is nil. Evidence
is gathered at learning-grade commits (no raw tail, not raw, not an English
reading), not at chunked auto-commits:

- intended keys per committed syllable, from `LexiconDecoder.readings(of:)`;
- one-key substitutions the committed text repaired: weight 1 when the user
  picked it, 0.25 when it only went unchallenged;
- Backspace re-types: the keys before a Backspace streak against the keys
  once they are back at that length, counted only when exactly one symbol key
  changed;
- reverts: the top candidate before the first explicit pick used a repair on
  a syllable that the committed text spells exactly as typed. Each revert
  cancels 3 slips.

Constants: half-life 3000 syllables, prior 50 opportunities at the generic
rate, learned floor 1.2, step 0.2 per commit toward cheaper and 1.0 toward
generic. The store holds keys and counts, never text.

Replay (`ChannelLearningSweepTests`): the synthetic user types the 40 dev
sentences 6 times. Each ㄣ is typed as ㄥ at the given rate, and 30% of slips
are noticed at once (Backspace, retype). Otherwise the user picks the right
sentence when it is in the list, else commits. Word learning is on in both
arms. Afterwards, the 40 holdout sentences, never typed in training, are typed
with every ㄣ slipped, and only the first-pass preview is scored. 5 seeds per
arm.

| user | learned ㄥ→ㄣ cost | holdout slipped first-pass, generic → learned | exact ㄥ kept |
|---|---|---|---|
| never slips | none | 71.4% → 71.4% | 77.8% → 77.8% |
| slips 10% | 3.0-4.5 | 71.4% → 82.9% | unchanged |
| slips 30% | 2.3-3.0 | 71.4% → 90.5% | unchanged |
| slips 60% | 1.7-1.9 | 71.4% → 90.5% | unchanged |
| 30%, then 4x as long at 0% | none (decayed back) | 71.4% → 71.4% | unchanged |

Not falsified. The learned cost tracks the slip rate. It generalizes to
sentences never typed in training, which word learning cannot do. No exact
ㄥ holdout sentence flipped (the 77.8% ceiling is the decoder's own exact-input
miss rate on that set). A user who never slips learns nothing, and a dropped
habit decays back to generic. The 60% user is still above the floor after 6
epochs: that is the bounded step working as intended.

Not done:
- Wiring the adapters: a macOS preference and store path, a Linux/C ABI
  switch, and "Clear learned typos" next to clearing learned phrases. Until
  then it is reachable only through `SessionSettings` in the core.
- Real typing. The synthetic user slips one fixed pair and corrects
  perfectly.
- The touch half: per-key tap distributions, which need a touch surface
  wired to `InputSession`.

The replay takes ~8 minutes in a release build because every keystroke
refreshes the session.

Run: `MISSTYPE_CHANNEL_SWEEP=1 swift test -c release -Xswiftc -enable-testing
--filter 'ChannelSweepTests|ChannelLearningSweepTests'` after
`python3 script/prepare_lexicon.py`. Tests: `ChannelModelTests` (learner:
bounded steps, floor, reverts, decay, persistence; evidence; session
re-type).

## Measures

Track phrase-level character error rate, syllable error rate, commit latency, p50/p95 decode latency, backspaces or replays, candidate interruptions, and task completion time. Log confidence and decoder source for every result. Run a fixed synthetic fixture set plus consented user sessions kept outside the repository.

The main comparison is not raw key accuracy. It is whether users can capture thoughts with fewer interruptions at an acceptable final reconstruction quality.

Long-term positioning: use [vChewing](https://github.com/vChewing/vChewing-macOS)
as the recommended mature Zhuyin baseline. Misstype does not aim to reproduce
vChewing's full feature surface; rather, vChewing provides a daily-usable
stability and candidate flow reference. Misstype's focused differentiators
are learned mixed Chinese/English typing and paired fuzzy correction: combine
keyboard edit evidence with touch-coordinate hypotheses, preserve the raw
trace, and measure adoption, false switches, repair rate, false repairs,
latency, and candidate interruptions against fixed replayable fixtures.

## Open questions

Competitor comparison and feature ideas: [`competitors.md`](competitors.md).

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

- Settings window (landed 2026-09-29): the 360pt utility panel became a full `SettingsWindow` (SwiftUI, sidebar: General / Decoding / Learning / Jev Assist / About; controls bind to the same `Misstype*` UserDefaults keys). UI strings go through `L()` with English keys and `Resources/{zh-Hant,zh-Hans,ja}.lproj/Localizable.strings`, following the system language; `tools/check_localizations.py` fails on missing or stale keys. Manual check pending: language switch, Jev consent alert, Clear learned phrases.
