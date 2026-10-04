# Chinese Zhuyin Decoding and Composition Engines: Technical Survey

[繁體中文](decoding-engines.md) | **English**

This document analyzes the algorithms and architecture paradigms used in Chinese Zhuyin (Bopomofo) input methods to transform keystroke sequences into candidate words and sentence structures, contrasting the engineering trade-offs between latency, footprint, toneless support, typo tolerance, and context learning.

---

## 1. Architectural Paradigms

Existing Zhuyin input method engines can be categorized into six major architectural paradigms:

### Paradigm 1: DAG with Word Frequencies (Unigram DAG / Gramambular)
- **Representative Projects**: [vChewing](https://github.com/vChewing/vChewing-macOS), McBopomofo
- **Core Algorithm**:
  - Valid syllable segmentations form a Directed Acyclic Graph (DAG) of dictionary words.
  - Words are scored based on unigram lexicon frequencies, often augmented with a length bias to prevent over-segmentation.
  - Dijkstra or Viterbi dynamic programming finds the path with the maximum cumulative score.
- **Strengths**:
  - Deterministic and easy to debug.
  - Linear time complexity relative to sentence length; minimal decode latency (< 1 ms).
  - Compact data footprint (a few megabytes), minimal memory usage.
- **Limitations**:
  - Blind to adjacent word co-occurrence (P(word_i | word_{i-1})).
  - Ambiguities (such as homophones or toneless collisions) rely entirely on exact tones or explicit manual candidate selection.

---

### Paradigm 2: Bigram Markov Language Models
- **Representative Projects**: ChiaKey, Yahoo KeyKey
- **Core Algorithm**:
  - Evaluates transitions between adjacent words using transition probabilities P(word_i | word_{i-1}). During dynamic programming, path edge weights combine the word's own frequency and the preceding word's transition bonus.
- **Findings & Challenges** (from our measurements in `tools/bigram_eval.py`):
  - **High information entropy in Zhuyin**: Unlike toneless Pinyin, Zhuyin carries tones inherently. Empirical tests show that character-level bigrams produce variance that steamrolls word unigram scores and tone accuracy, degrading sentences into common-character fragments.
  - **Regression on toneless input**: Word bigram tables calibrated for toned input often misclassify homophones across tones (e.g., flipping 他 to 她, or 時間 to 事件) when users omit tones.
  - **Footprint and latency cost**: Storing hundreds of thousands of word-pair transitions bloats package sizes to 30–50+ MB. Cache misses from hash/database lookups approximately doubled decode latency (from ~27 ms to 55 ms).

---

### Paradigm 3: Spelling Algebra and Prefix Tries (Spelling Algebra + Trie)
- **Representative Projects**: Rime (Squirrel / Weasel)
- **Core Algorithm**:
  - Stores lexicon prefixes in a Marisa-Trie (`prism.bin`).
  - Uses declarative spelling algebra rules at build time to statically expand toneless and phonetic variations into matching valid syllables.
  - At runtime, `ScriptTranslator` builds a syllable graph, applying length bias, unigram frequencies, and user history (Frecency: frequency + recency decay).
- **Strengths**:
  - Highly expressive and customizable across different input schemas (Bopomofo, Pinyin, Cangjie).
  - Compact prefix trie storage.
- **Limitations**:
  - **Boolean expansion**: Toneless matching is binary rather than probabilistic; it lacks continuous distance penalties for acoustic or spatial key errors.
  - **Disambiguation load**: Omitted tones cause combinatorial candidate expansion in the prefix trie. Without automatic chunked commits, long un-toned sentences easily diverge from user intent.

---

### Paradigm 4: Classic Backward Maximum Matching
- **Representative Projects**: libchewing, Ari IME
- **Core Algorithm**:
  - Scans backwards from the end of the input buffer to match the longest lexicon entries, aided by part-of-speech tagging or heuristic rules.
- **Strengths**:
  - Mature, straightforward, and highly efficient for clean, toned, standard sentence patterns.
- **Limitations**:
  - Difficult to adapt to continuous toneless typing.
  - Inflexible when handling typos or adjacent-key errors; unregistered words can disrupt segmentation across the entire sentence.

---

### Paradigm 5: On-Device / Cloud Neural Models (Neural LM / LLM Reranking)
- **Representative Projects**: ZingIME (on-device AI selection claim), experimental LLM rerankers
- **Core Algorithm**:
  - Generates top candidates via traditional rules, then applies a small Transformer, SLM, or remote LLM to rescore or rerank based on sentence context.
- **Findings & Challenges** (from `tools/lm_choose.py` evaluations):
  - **Size barrier**: On-device neural models typically require hundreds of megabytes (e.g., ZingIME's download size is 271.6 MiB).
  - **Latency friction**: Per-keystroke interactivity demands < 10 ms response times, whereas neural inference often takes tens to hundreds of milliseconds.
  - **Calibration issues**: Small language models frequently exhibit high-confidence hallucinations or position biases, compromising deterministic output.

---

### Paradigm 6: Unified Penalty Lattice & Dynamic Learning (Unified Penalty Lattice + Beam Search)
- **Representative Project**: **Misstype**
- **Core Algorithm**:
  - **Unified Cost Lattice**: Evaluates tone absence, keyboard edit errors (neighbor keys, transpositions, omissions), Gaussian touch coordinate distances, and unigram lexicon frequencies inside a single, unified penalty framework.
  - **Bounded Beam Search**: Clean, repaired, and toneless paths compete in a single dynamic programming lattice with strict pruning (beam width 16), maintaining a 1～5 ms full-sentence decode budget per keystroke.
  - **Context-Keyed Learning**: Instead of a multi-megabyte static bigram table, records user selections on demand as `previous_word | readings -> picked_text` (e.g., `下次 | ㄗㄞ -> 再`). This resolves homophone ties using local context without polluting global rankings.
- **Strengths**:
  - Compact footprint (plain-text TSV data totaling ~6 MB), minimal runtime memory.
  - Robust error recovery: preserves full input traces and handles typos or omitted tones naturally in real-time.

---

## 2. Comparative Matrix

| Dimension | Unigram DAG (vChewing) | Bigram Markov (ChiaKey) | Spelling Algebra (Rime) | Max Matching (libchewing) | Neural LM (ZingIME) | Misstype |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Primary Scoring** | Unigram + Length Bias | Unigram + Bigram Transitions | Unigram + Rule Expansion | Greedy Backward Match | Neural Context Probabilities | Lexicon Unigram − Penalty Costs ＋ Local Boosts |
| **Toneless Support** | None (Tones required) | Yes (Cross-tone drift observed) | Yes (Static rule derivation) | Weak (Biased to complete tones) | Yes (Model disambiguation) | Native (Scored as soft penalty in DP) |
| **Typo Tolerance** | None | None | Pre-defined fuzzy sounds only | None | None | Native (Edit distance + Touch coordinates) |
| **Decode Latency** | < 1 ms | ≈ 25～55 ms | < 5 ms | < 1 ms | Tens to hundreds of ms | 1～5 ms |
| **Package / Data Size** | Lightweight (few MB) | Large (30–50 MB) | Medium (10–30 MB) | Minimal (few MB) | Very Large (200 MB+) | Minimal (~6 MB) |
| **Context Adaptation** | User Dictionary | Static Bigram + User Lexicon | Frecency Decay | Phrase Weighting | Pretrained Weights | Local Context-Keyed Learning |

---

## 3. Engineering Conclusions

1. **Static Bigram tables do not transfer cleanly to Zhuyin**:
   Zhuyin input possesses high information density. Empirical findings show that static bigram corpora introduce variance that disrupts tone and word weights, especially during toneless or typo-prone typing.
2. **Local context rules outperform global n-gram tables**:
   True ambiguities in Zhuyin (such as 在/再 or 做/作) involve a small set of residual homophones. Targeted local learning (`previous_word | reading -> selection`) resolves over 95% of individual ambiguities without bloating data structures.
3. **A unified penalty lattice is the scalable path forward**:
   Modern typing on software keyboards produces frequent neighbor-key slips and omitted tones. Unifying acoustic hints, edit distances, and touch coordinates inside a single dynamic programming lattice achieves the best balance between low latency and forgiving text capture.

---

## 4. How to Choose: Practical Trade-offs and Scenarios

Input method engines are shaped by engineering trade-offs rather than pure superiority. Each reflects different assumptions about user typing habits and hardware constraints:

- **For absolute control, surgical precision, and rock-solid stability → [vChewing](https://github.com/vChewing/vChewing-macOS) or McBopomofo**
  - **Best for**: Users who type exact tones on physical keyboards and want predictable, zero-guesswork output without algorithmic second-guessing.
  - **Experience**: Complete determinism, sub-millisecond decode latency (< 1 ms), and a pure typing flow.

- **For infinite customization, multi-platform parity, and esoteric schemas → [Rime](https://rime.im/) (Squirrel / Weasel)**
  - **Best for**: Power users, alternative layout typists, and hackers who manage multi-platform dotfiles and custom spelling algebra schemas.
  - **Experience**: Unrivaled YAML-driven extensibility and vast community lexicon ecosystems.

- **For classic desktop sentence flow and Taiwan phrase collocations → ChiaKey or KeyKey**
  - **Best for**: Typists fond of the classic Yahoo KeyKey sentence composition feel, valuing pre-calibrated Taiwan idioms and domain phrases.
  - **Experience**: Smooth phrase-pair stitching for steady desktop writing, at the cost of a 30–50 MB footprint.

- **For whole-sentence context selection regardless of resource footprint → ZingIME / Neural LM methods**
  - **Best for**: Modern macOS users who want on-device AI to automatically resolve tricky homophones (e.g., 在 vs. 再) and have ample disk space and RAM.
  - **Experience**: Context-aware candidate selection, traded against a ~270 MB install footprint and non-negligible inference overhead.

- **For fast blind-typing, forgiving typos, seamless English mixing, and minimal footprint → Misstype (隨打注音)**
  - **Best for**: Rapid typists who frequently omit tones, slip on adjacent keys, mix English without toggling Caps Lock, and demand real-time (< 5 ms) responsiveness in a compact (~6 MB) package.
  - **Experience**: Silent, unified error recovery with local context learning that remembers explicit picks without global noise.
  - **Bonus reason**: And of course, being part of Yukai's circle of friends and family—or succumbing to the author's relentless cajoling, arm-twisting, and forced beta-testing.
