import Foundation

public struct SentenceCandidate: Equatable {
    public let text: String
    public let score: Double
    public let repairs: Int
    public let unresolved: Int
    /// Word alignment: which syllable range produced which char range.
    /// Powers the IME syllable cursor (caret placement, focused-span
    /// lookup). Empty for legacy constructions; decode always fills it.
    public let alignment: [WordSpan]
    /// The syllables this candidate was decoded from — alignment indexes
    /// into this list. Repair and pending-run segmentation happen inside the
    /// decoder, so the composition alone cannot rebuild it (a toneless run
    /// is one fused syllable there). Empty for legacy constructions.
    public let syllables: [Syllable]
    /// Syllable range of each Zhuyin run in decodeSegments order (empty runs
    /// included, so indexes match the positional session-pin keys).
    public let runs: [Range<Int>]

    public init(text: String, score: Double, repairs: Int, unresolved: Int,
                alignment: [WordSpan] = [], syllables: [Syllable] = [],
                runs: [Range<Int>] = []) {
        self.text = text
        self.score = score
        self.repairs = repairs
        self.unresolved = unresolved
        self.alignment = alignment
        self.syllables = syllables
        self.runs = runs
    }
}

/// One decoded word: syllable range in the input array, char range in text.
public struct WordSpan: Equatable {
    public let syllables: Range<Int>
    public let chars: Range<Int>
    public init(syllables: Range<Int>, chars: Range<Int>) {
        self.syllables = syllables
        self.chars = chars
    }
}

/// Preedit string with a visible cursor marker, for panels that must not
/// depend on the client drawing the marked-text caret (some apps never do —
/// vChewing ships a floating composition buffer for the same reason).
/// `caret` is a UTF-16 offset; out-of-range clamps, misaligned offsets fall
/// back to appending rather than splitting a unit. The marker is "|" (not a
/// block element: those carry a full advance width and trail a blank gap).
public func preeditWithCursor(_ text: String, caretUTF16 caret: Int,
                              marker: Character = "|") -> String {
    let units = text.utf16
    let clamped = max(0, min(caret, units.count))
    let utf16Index = units.index(units.startIndex, offsetBy: clamped)
    if let index = String.Index(utf16Index, within: text) {
        return String(text[..<index]) + String(marker) + String(text[index...])
    }
    return text + String(marker)
}

public final class LexiconDecoder {
    private final class Node {
        var children: [String: Node] = [:]
        var entries: [(text: String, score: Double)] = []
        /// Single-syllable nodes only: entries rescored for toneless input
        /// (nil = same as `entries`). See `init(tsv:toneless:)`.
        var tonelessEntries: [(text: String, score: Double)]?
    }
    /// Full per-reading entries, best-first (was: top 3). +5% entries
    /// corpus-wide, so frequency-buried daily chars (鍵 is #22 under
    /// ㄐㄧㄢˋ) exist in the trie at all — single-char queries page real
    /// homophones via segmentOptions instead of repair junk, and one
    /// explicit pick (+6) can then lock them top-1.
    /// The hot decode loop does NOT walk all of these (see
    /// decodeEntriesPerNode); beam paths stay top-16, so sentences
    /// barely notice.
    /// Decode-time entries per node. Multi-syllable beams only ever show
    /// 16, so iterating past a few buys nothing but latency (measured ~2x
    /// at 8, ~3x at full walk on 9–26 syllables); single-syllable queries
    /// walk the full node below (they have no lattice to explode: ~1 ms
    /// for 68 entries). Deep homophone paging walks the full node via
    /// segmentOptions instead.
    private static let decodeEntriesPerNode = 4
    private let root = Node()
    private var readings: Set<String> = []
    private var toneless: [String: Set<String>] = [:]
    public private(set) var entryCount = 0
    /// Optional homophone bigram overlay (nil = byte-identical decode).
    public var contextBigrams: ContextBigrams?
    /// Cost per dictionary word on a path (0 = off). McBopomofo single-char
    /// scores count bound morphemes, so splitting a word into chars is
    /// over-rewarded; a per-token cost rebalances word vs chars.
    public var wordPenalty = 0.0

    /// `toneless` rows (`reading<TAB>text<TAB>score`) override a single
    /// char's score only when its syllable was typed without a tone — the
    /// only case that compares chars across tones (吃 ㄔ vs 持 ㄔˊ). Toned
    /// input and multi-syllable words never see them.
    public convenience init(tsv: String, toneless: String) {
        self.init(tsv: tsv)
        var overrides: [String: [String: Double]] = [:]
        for line in toneless.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count == 3, let score = Double(fields[2]), score.isFinite else { continue }
            overrides[String(fields[0]), default: [:]][String(fields[1])] = score
        }
        for (reading, texts) in overrides {
            guard let node = root.children[reading] else { continue }
            node.tonelessEntries = node.entries.map { ($0.text, texts[$0.text] ?? $0.score) }
                .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        }
    }

    public init(tsv: String) {
        for line in tsv.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 3, let score = Double(fields[2]), score.isFinite else { continue }
            let parts = fields[0].split(separator: "-").map(String.init)
            guard !parts.isEmpty && parts.count <= 8 else { continue }
            var node = root
            for reading in parts {
                readings.insert(reading)
                toneless[Self.withoutTone(reading), default: []].insert(reading)
                if node.children[reading] == nil { node.children[reading] = Node() }
                node = node.children[reading]!
            }
            node.entries.append((String(fields[1]), score))
            node.entries.sort { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
            entryCount += 1
        }
    }

    private static func withoutTone(_ text: String) -> String {
        String(text.filter { !"ˊˇˋ˙".contains($0) })
    }

    private func alternatives(_ syllable: Syllable, fuzzy: Bool, toneTolerance: Bool = true) -> [(String, Double, Int)] {
        let reading = syllable.reading
        // Clean readings first; repair classes join the same list when fuzzy
        // is on (never gated: a valid-base typo like 更-for-功 or 業-for-越
        // must still compete — costs, not gates, protect exact input).
        // Tiers: exact 0, toneless 0.5, explicit-tone-mismatch 4.0,
        // transpose 4, substitute/phonetic 5, insert/delete 6.
        var scored: [String: (cost: Double, correction: Int)] = [:]
        func add(_ reading: String, _ cost: Double, _ correction: Int) {
            if let prev = scored[reading], prev.cost <= cost { return }
            scored[reading] = (cost, correction)
        }
        if syllable.tone != nil {
            // Explicit tone — including the space key's first tone (""), as
            // in RIME's bopomofo schema: deliberate evidence (it cost a
            // keystroke), so a same-base other-tone rival pays 4.0 — above
            // toneless spread (0.5) and beside transpose (4), below
            // substitute (5). Measured 2026-09-18: at 2.0, 作ˋ outscored
            // explicitly-typed 左ˇ (-6.2-2.0 > -8.8); at 4.0 the typed tone
            // holds while the rival stays listed for genuine tone typos.
            // Space used to be weak (0.5, "often a separator habit"), which
            // let frequency override a typed first tone (喝->和, 約->說,
            // 交->教); continuous typing now converts live instead of
            // needing space, so space means ˉ (user decision 2026-09-27).
            if readings.contains(reading) { add(reading, 0, 0) }
            if toneTolerance, let variants = toneless[Self.withoutTone(reading)] {
                for variant in variants where variant != reading { add(variant, 4.0, 1) }
            }
        } else if let variants = toneless[Self.withoutTone(reading)] {
            // Toneless (nil) leaves the tone fully to the engine.
            for variant in variants { add(variant, 0.5, 0) }
        }
        if fuzzy {
            // Auto-repair: adjacent transposition (key order slips), neighbor
            // and phonetic-confusion substitution, deletion of an extra key,
            // insertion of a missing key.
            let tonelessProbe = syllable.tone == nil
            func consider(keys: [String], cost: Double) {
                let repaired = Syllable(keys: keys, tone: syllable.tone).reading
                if !tonelessProbe {
                    if readings.contains(repaired) { add(repaired, cost, 1) }
                    return
                }
                for variant in toneless[Self.withoutTone(repaired)] ?? [] {
                    add(variant, cost, 1)
                }
            }
        let base = syllable.keys
        // Snapshot BEFORE phonetic: transpose/sub/delete/insert stay gated
        // on no-clean-reading (classic rescue), while phonetic confusions
        // ride along always (see below).
        let cleanEmpty = scored.isEmpty
        // Phonetic confusions ride along always: 1–2 options per key, so
        // they cost almost nothing and catch real ㄧㄨㄩ / 捲平舌 slips that
        // land on another valid reading (業-for-越).
        for index in base.indices {
            for replacement in ZhuyinKeyboard.phoneticConfusions[base[index]] ?? [] {
                var keys = base
                keys[index] = replacement
                consider(keys: keys, cost: 5)
            }
        }
        if cleanEmpty {
            for index in base.indices {
                for replacement in ZhuyinKeyboard.neighbors(of: base[index]) {
                    var keys = base
                    keys[index] = replacement
                    consider(keys: keys, cost: 5)
                }
                if index + 1 < base.count {
                    var keys = base
                    keys.swapAt(index, index + 1)
                    consider(keys: keys, cost: 4)
                }
                if base.count > 1 {
                    var keys = base
                    keys.remove(at: index)
                    consider(keys: keys, cost: 6)
                }
            }
        }
        // Insertion scans 37 symbols per gap — the most speculative class,
        // so it runs only on no-clean-reading like the rest (s3→你).
        if cleanEmpty, base.count < Self.maxSyllableKeys {
            for position in 0...base.count {
                for symbol in ZhuyinKeyboard.symbols.keys {
                    var keys = base
                    keys.insert(symbol, at: position)
                    consider(keys: keys, cost: 6)
                }
            }
        }
        }
        return scored.sorted {
            $0.value.cost == $1.value.cost ? $0.key < $1.key : $0.value.cost < $1.value.cost
        }.prefix(16).map { ($0.key, $0.value.cost, $0.value.correction) }
    }

    /// Longest symbol-only run that can form one syllable (initial+medial+final).
    private static let maxSyllableKeys = 4

    /// Split pending symbol keys into syllable hypotheses, cheapest first.
    /// A slice is viable when it has an exact, toneless, or repair reading;
    /// slices rank by their cheapest option cost (clean 0–0.5, explicit-tone
    /// mismatch 4.0, transpose 4, substitute 5, insert/delete 6), so one corrupt
    /// syllable no longer vetoes the whole run and caps prune by cost,
    /// never by arrival order. Mixed clean+repaired segmentations compete
    /// in a single lattice.
    private func segmentations(of keys: [String], fuzzy: Bool, toneTolerance: Bool = true) -> [[Syllable]] {
        guard !keys.isEmpty else { return [[]] }
        var lattice: [[(syllables: [Syllable], cost: Double)]] =
            Array(repeating: [], count: keys.count + 1)
        lattice[0] = [([], 0)]
        for start in 0..<keys.count {
            lattice[start].sort { $0.cost < $1.cost }
            lattice[start] = Array(lattice[start].prefix(24))
            guard !lattice[start].isEmpty else { continue }
            for len in 1...min(Self.maxSyllableKeys, keys.count - start) {
                let slice = Array(keys[start..<start + len])
                guard slice.allSatisfy({ ZhuyinKeyboard.symbols[$0] != nil }) else { continue }
                let probe = Syllable(keys: slice, tone: nil)
                let options = alternatives(probe, fuzzy: fuzzy, toneTolerance: toneTolerance)
                guard let cheapest = options.map(\.1).min() else { continue }
                for prefix in lattice[start].prefix(8) {
                    lattice[start + len].append((prefix.syllables + [probe], prefix.cost + cheapest))
                    if lattice[start + len].count >= 64 { break }
                }
            }
        }
        lattice[keys.count].sort { $0.cost < $1.cost }
        return Array(lattice[keys.count].prefix(12).map(\.syllables))
    }

    /// Live conversion (RIME-style continuous typing): how many leading
    /// pending keys to convert now. The whole run when it segments cleanly;
    /// otherwise drop up to 3 trailing keys — the syllable still being typed
    /// (ㄉ of 好ㄉ) stays raw instead of being "repaired" into a random char.
    /// Otherwise: a run that cannot even start with a syllable (ㄏㄏㄏㄏ) is
    /// 注音文 and stays raw whole; a run that starts clean has a typo inside
    /// and converts whole with repair, exactly as commit used to.
    public func livePendingCut(_ keys: [String], toneTolerance: Bool = true) -> Int {
        guard !keys.isEmpty else { return 0 }
        func clean(_ count: Int) -> Bool {
            count == 0 || !segmentations(of: Array(keys.prefix(count)), fuzzy: false,
                                         toneTolerance: toneTolerance).isEmpty
        }
        for cut in stride(from: keys.count, through: max(0, keys.count - 3), by: -1) where clean(cut) {
            return cut
        }
        let startsClean = (1...min(Self.maxSyllableKeys, keys.count)).contains(where: clean)
        return startsClean ? keys.count : 0
    }

    /// Public pending-run segmentation for the IME syllable cursor: the
    /// cursor rebuilds the converted syllable list as
    /// complete + segmentKeys(pending)[0] and validates it against the top
    /// candidate's alignment before trusting any focused span.
    public func segmentKeys(_ keys: [String], fuzzy: Bool, toneTolerance: Bool = true) -> [[Syllable]] {
        segmentations(of: keys, fuzzy: fuzzy, toneTolerance: toneTolerance)
    }

    /// Distinct word options covering one syllable span, for the cursor's
    /// focused segment. Same option/trie/score scale as decode, restricted
    /// to spans exactly equal to `span` — deterministic, beam-independent.
    /// Single-syllable spans list up to 64 (the homophone browser: every IME
    /// lets you page through 同音字; multi-char spans cap at 16 like the
    /// beam — deep word lists never pay off).
    public func segmentOptions(_ syllables: [Syllable], span: Range<Int>, fuzzy: Bool = true, toneTolerance: Bool = true) -> [(text: String, score: Double)] {
        guard !span.isEmpty, span.count <= 8,
              span.lowerBound >= 0, span.upperBound <= syllables.count else { return [] }
        let cap = span.count == 1 ? 64 : 16
        let options = syllables.map { alternatives($0, fuzzy: fuzzy, toneTolerance: toneTolerance) }
        var found: [String: Double] = [:]
        func walk(_ node: Node, _ index: Int, _ penalty: Double) {
            if index == span.upperBound {
                for entry in node.entries {
                    let score = entry.score - penalty
                    if found[entry.text].map({ $0 >= score }) ?? false { continue }
                    found[entry.text] = score
                }
                return
            }
            for (reading, cost, _) in options[index] {
                guard let child = node.children[reading] else { continue }
                walk(child, index + 1, penalty + cost)
            }
        }
        walk(root, span.lowerBound, 0)
        return found.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(cap).map { (text: $0.key, score: $0.value) }
    }
    /// Split a tone-terminated run that is not viable as one syllable: the tone
    /// belongs to the trailing piece (the syllable just finished), the lead is
    /// segmented tonelessly. Without this, one mid-sentence tone key fuses the
    /// whole pending run into a single giant syllable and everything falls
    /// back to raw Bopomofo. Falls back to the original syllable (fuzzy rescue
    /// in decode) when no clean split exists.
    private func repairComplete(_ syllable: Syllable, toneTolerance: Bool = true) -> [[Syllable]] {
        if !alternatives(syllable, fuzzy: false).isEmpty { return [[syllable]] }
        guard syllable.keys.count > 1 else { return [] }
        var byTail: [[[Syllable]]] = []
        for tailLen in 1...min(Self.maxSyllableKeys, syllable.keys.count - 1) {
            let tail = Syllable(keys: Array(syllable.keys.suffix(tailLen)), tone: syllable.tone)
            guard !alternatives(tail, fuzzy: false, toneTolerance: toneTolerance).isEmpty else { continue }
            let leadKeys = Array(syllable.keys.prefix(syllable.keys.count - tailLen))
            byTail.append(segmentations(of: leadKeys, fuzzy: false, toneTolerance: toneTolerance)
                .prefix(6).map { $0 + [tail] })
        }
        // Round-robin across tail lengths: emitting all of tail 1 first let a
        // one-symbol tail (ㄟ 欸) fill the caller's prefix(6), so the real
        // final syllable (ㄉㄨㄟ) was never decoded — toneless runs ended in
        // 大都欸 / 一誒 / 主恩 (tools/cursor_replay.py, 2026-09-27).
        var out: [[Syllable]] = []
        for rank in 0..<6 {
            for options in byTail where rank < options.count {
                out.append(options[rank])
                if out.count >= 12 { return out }
            }
        }
        // No valid tail (a typo, or an initial alone: 眼睛ㄐ + Space): keep
        // the clean lead and hand the invalid tail to decode as-is, where
        // fuzzy repair gets a shot and anything left stays raw. Returning
        // nothing made the WHOLE run one unresolved syllable, so every
        // converted char reverted to Bopomofo (ㄧㄢㄐㄧㄥㄐ; user report
        // 2026-09-27, made common by Space now meaning first tone).
        // A run of <= 4 keys may still be ONE mistyped syllable (ㄘㄧˋ ->
        // 次ˋ by deletion), so it keeps its whole-syllable repair chance;
        // a longer run cannot be one syllable and must not fall back whole.
        if out.isEmpty {
            if syllable.keys.count <= Self.maxSyllableKeys { out.append([syllable]) }
            for tailLen in 1...min(3, syllable.keys.count - 1) {
                let leadKeys = Array(syllable.keys.prefix(syllable.keys.count - tailLen))
                guard let lead = segmentations(of: leadKeys, fuzzy: false,
                                               toneTolerance: toneTolerance).first else { continue }
                out.append(lead + [Syllable(keys: Array(syllable.keys.suffix(tailLen)), tone: syllable.tone)])
            }
        }
        return out
    }
    /// Decode tone-terminated syllables plus an unsegmented pending key run.
    /// Covers all three styles: toneless-continuous, space-separated, toned.
    /// Complete runs fused by a mid-sentence tone key are repaired first.
    /// Falls back to the legacy single-syllable reading
    /// (surfaced as unresolved) when nothing segments.
    public func decodeComposition(complete: [Syllable], pendingKeys: [String], fuzzy: Bool = true, toneTolerance: Bool = true, userLexicon: UserLexicon? = nil, locked: UserLexicon? = nil) -> [SentenceCandidate] {
        // Expand fused complete runs (usually a no-op of one option each).
        var expandedComplete: [[Syllable]] = [[]]
        for syllable in complete {
            let options = repairComplete(syllable, toneTolerance: toneTolerance)
            let chosen = options.isEmpty ? [[syllable]] : options
            var next: [[Syllable]] = []
            for prefix in expandedComplete.prefix(6) {
                for option in chosen.prefix(6) {
                    next.append(prefix + option)
                    if next.count >= 12 { break }
                }
                if next.count >= 12 { break }
            }
            expandedComplete = next
        }
        var segmentOptions: [[Syllable]] = [[]]
        if !pendingKeys.isEmpty {
            segmentOptions = segmentations(of: pendingKeys, fuzzy: false, toneTolerance: toneTolerance)
            if segmentOptions.isEmpty && fuzzy {
                segmentOptions = segmentations(of: pendingKeys, fuzzy: true, toneTolerance: toneTolerance)
            }
            if segmentOptions.isEmpty {
                return decode(complete + [Syllable(keys: pendingKeys, tone: nil)], fuzzy: fuzzy, toneTolerance: toneTolerance, userLexicon: userLexicon, locked: locked)
            }
        }
        var merged: [SentenceCandidate] = []
        func merge(_ syllables: [Syllable], budget: inout Int) {
            for candidate in decode(syllables, fuzzy: fuzzy, toneTolerance: toneTolerance, userLexicon: userLexicon, locked: locked) {
                if let same = merged.firstIndex(where: { $0.text == candidate.text }) {
                    if merged[same].score >= candidate.score { continue }
                    merged.remove(at: same)
                }
                merged.append(candidate)
                merged.sort { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
                merged = Array(merged.prefix(16))
            }
            budget -= 1
        }
        var budget = 12
        for prefix in expandedComplete {
            for segmentation in segmentOptions {
                guard budget > 0 else { break }
                merge(prefix + segmentation, budget: &budget)
            }
        }
        // Repair track: clean segmentations can hide one corrupt syllable
        // behind cheap single-char junk, so when the best merge so far is
        // not fully clean, also decode repair-inclusive segmentations the
        // clean track never admitted. Skipped for clean input (same cost as
        // before); noisy input pays a few extra millisecond decodes.
        if fuzzy, !pendingKeys.isEmpty,
           merged.first.map({ $0.unresolved > 0 || $0.repairs > 0 }) ?? true {
            let cleanForms = Set(segmentOptions.map { $0.map(\.reading).joined(separator: " ") })
            var extra = 0
            for segmentation in segmentations(of: pendingKeys, fuzzy: true, toneTolerance: toneTolerance) {
                if extra >= 6 || budget <= 0 { break }
                if cleanForms.contains(segmentation.map(\.reading).joined(separator: " ")) { continue }
                extra += 1
                for prefix in expandedComplete.prefix(3) {
                    guard budget > 0 else { break }
                    merge(prefix + segmentation, budget: &budget)
                }
            }
        }
        return merged
    }

    /// Decode an ordered mixed span: Zhuyin runs convert, punctuation passes
    /// through in place, one commit at the end. Words never span punctuation,
    /// but the trailing unfinished run still decodes jointly with its own
    /// run — so punct-free input behaves exactly like decodeComposition.
    public func decodeSegments(_ segments: [Composition.Segment], pendingKeys: [String], fuzzy: Bool = true, toneTolerance: Bool = true, userLexicon: UserLexicon? = nil, locked: UserLexicon? = nil) -> [SentenceCandidate] {
        var runs: [[Syllable]] = [[]]
        var seps: [String] = []
        for segment in segments {
            switch segment {
            case .syllable(let syllable): runs[runs.count - 1].append(syllable)
            case .punct(let mark), .latin(let mark):
                runs.append([])
                seps.append(mark)
            }
        }
        let empty = SentenceCandidate(text: "", score: 0, repairs: 0, unresolved: 0)
        var runTops: [[SentenceCandidate]] = []
        for (index, run) in runs.enumerated() {
            // Every run goes through decodeComposition so fused tone runs
            // are repaired the same way with or without punctuation around.
            // (decodeSegments must not call decode() directly — that bypass
            // once silently disabled repair on all IME paths.)
            let trailing = index == runs.count - 1
            let tops = decodeComposition(complete: run,
                                         pendingKeys: trailing ? pendingKeys : [],
                                         fuzzy: fuzzy, toneTolerance: toneTolerance,
                                         userLexicon: userLexicon,
                                         locked: locked?.pins(forRun: index))
            runTops.append(tops.isEmpty ? [empty] : tops)
        }
        func render(_ picks: [SentenceCandidate]) -> SentenceCandidate {
            var text = ""
            var score = 0.0
            var repairs = 0
            var unresolved = 0
            // Rebase per-run alignment into whole-span coordinates: char
            // offsets accumulate through separators, syllable offsets through
            // each run's consumed length (== its alignment's last end).
            var align: [WordSpan] = []
            var syllables: [Syllable] = []
            var runs: [Range<Int>] = []
            var sylBase = 0
            for (index, pick) in picks.enumerated() {
                let charBase = text.utf16.count
                for span in pick.alignment {
                    align.append(WordSpan(
                        syllables: (span.syllables.lowerBound + sylBase)..<(span.syllables.upperBound + sylBase),
                        chars: (span.chars.lowerBound + charBase)..<(span.chars.upperBound + charBase)))
                }
                let consumed = pick.alignment.last?.syllables.upperBound ?? 0
                runs.append(sylBase..<sylBase + consumed)
                sylBase += consumed
                syllables += pick.syllables
                text += pick.text
                score += pick.score
                repairs += pick.repairs
                unresolved += pick.unresolved
                if index < seps.count { text += seps[index] }
            }
            return SentenceCandidate(text: text, score: score, repairs: repairs, unresolved: unresolved, alignment: align, syllables: syllables, runs: runs)
        }
        let base = runTops.map { $0[0] }
        var out = [render(base)]
        for (index, tops) in runTops.enumerated() {
            for alt in tops.dropFirst() {
                var picks = base
                picks[index] = alt
                out.append(render(picks))
                if out.count >= 64 { break }
            }
            if out.count >= 64 { break }
        }
        out.sort { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
        return Array(out.prefix(16))
    }

    public func decode(_ syllables: [Syllable], fuzzy: Bool = true, toneTolerance: Bool = true, userLexicon: UserLexicon? = nil, locked: UserLexicon? = nil) -> [SentenceCandidate] {        guard !syllables.isEmpty else { return [] }
        let options = syllables.map { alternatives($0, fuzzy: fuzzy, toneTolerance: toneTolerance) }
        // Context-keyed learning (previous word -> readings -> text), nil
        // unless the user lexicon holds any (see UserLexicon.contextKey).
        let contextRules = userLexicon?.contextRules()
        // Character-level settle pins (run-local UTF-16 offset -> unit): a
        // word earns pinBonus per settled char it reproduces, whatever its
        // boundaries — word-level settling froze 這 as a single-char word
        // and blocked the later merge into 這部 (這不電影).
        let settledUnits = locked?.settledUnits()
        var paths = Array(repeating: [SentenceCandidate](), count: syllables.count + 1)
        paths[0] = [SentenceCandidate(text: "", score: 0, repairs: 0, unresolved: 0)]
        // Beam of 16 per position, best score first, text ascending on ties.
        // Hot path (every keystroke re-decodes the whole composition), so:
        // `admits` rejects a hopeless score before the candidate (a long
        // string + alignment copy) is built, and text is compared as UTF-8
        // bytes — identical order/equality for NFC text, without Swift's
        // Unicode-normalizing String comparison.
        func admits(_ score: Double, at index: Int) -> Bool {
            paths[index].count < 16 || score >= paths[index][15].score
        }
        func precedes(_ a: SentenceCandidate, _ b: SentenceCandidate) -> Bool {
            a.score == b.score ? a.text.utf8.lexicographicallyPrecedes(b.text.utf8) : a.score > b.score
        }
        func sameText(_ a: String, _ b: String) -> Bool {
            guard a.utf8.count == b.utf8.count else { return false }
            let bytes = a.utf8.withContiguousStorageIfAvailable { left in
                b.utf8.withContiguousStorageIfAvailable { right in
                    memcmp(left.baseAddress, right.baseAddress, left.count) == 0
                }
            }
            return bytes.flatMap { $0 } ?? a.utf8.elementsEqual(b.utf8)
        }
        func add(_ candidate: SentenceCandidate, at index: Int) {
            if let same = paths[index].firstIndex(where: { sameText($0.text, candidate.text) }) {
                if paths[index][same].score >= candidate.score { return }
                paths[index].remove(at: same)
            }
            let position = paths[index].firstIndex { precedes(candidate, $0) } ?? paths[index].endIndex
            paths[index].insert(candidate, at: position)
            if paths[index].count > 16 { paths[index].removeLast() }
        }
        for start in syllables.indices {
            guard !paths[start].isEmpty else { continue }
            let prefixes = paths[start]
            // Long-string UTF-16 counts are O(n): once per prefix, not per entry.
            let prefixLengths = prefixes.map { $0.text.utf16.count }
            for (index, prefix) in prefixes.enumerated() where admits(prefix.score - 100, at: start + 1) {
                let raw = syllables[start].reading
                add(SentenceCandidate(text: prefix.text + raw,
                    score: prefix.score - 100, repairs: prefix.repairs,
                    unresolved: prefix.unresolved + 1,
                    alignment: prefix.alignment + [WordSpan(
                        syllables: start..<start + 1,
                        chars: prefixLengths[index]..<prefixLengths[index] + raw.utf16.count)]), at: start + 1)
            }
            // Previous word of each prefix, for context rules (run-local:
            // decode sees one run, so context never crosses punctuation).
            let previousWords: [String] = contextRules == nil && contextBigrams == nil ? [] : prefixes.map { prefix in
                guard let last = prefix.alignment.last else { return "" }
                let units = Array(prefix.text.utf16)
                guard last.chars.upperBound <= units.count else { return "" }
                return String(decoding: units[last.chars], as: UTF16.self)
            }
            var states: [(node: Node, penalty: Double, repairs: Int, readings: [String])] = [(root, 0, 0, [])]
            for end in start..<min(syllables.count, start + 8) {
                var next: [(node: Node, penalty: Double, repairs: Int, readings: [String])] = []
                for (node, penalty, repairs, readings) in states {
                    for (reading, cost, correction) in options[end] {
                        guard let child = node.children[reading] else { continue }
                        let span = readings + [reading]
                        next.append((child, penalty + cost, repairs + correction, span))
                        // Single-syllable inputs ARE homophone browsing: walk
                        // the full node (cheap, no lattice). Longer spans pay
                        // per extra entry with zero beam benefit past a few.
                        let entries = end == start && syllables[start].tone == nil
                            ? child.tonelessEntries ?? child.entries : child.entries
                        let cap = syllables.count == 1 ? entries.count : Self.decodeEntriesPerNode
                        let spanKey = UserLexicon.key(forReadings: span)
                        for (rank, entry) in entries.enumerated() {
                            // The cap trims the beam, never a user's pick: a
                            // homophone past it (page 2 of the picker) would
                            // otherwise be pinned yet unreachable, so the
                            // pick silently did nothing.
                            if rank >= cap {
                                guard let locked, !locked.isEmpty else { break }
                                if !locked.hasPin(readings: spanKey, text: entry.text) { continue }
                            }
                            // Session pin: a decisive bonus for the pinned
                            // (span, text) pair — paths through it always win
                            // (bonus dwarfs any score gap), longer covering
                            // words included, and no path ever starves (a
                            // filter could kill every route when the head
                            // re-segments; a dormant pin just adds nothing).
                            // Legacy pins (CLI --lock) are reading-only; the
                            // IME's are positional (run-local UTF-16 offset of
                            // the word start), so a path can collect a pin once
                            // and only where it was picked — reading-only pins
                            // paid per occurrence, and the decoder re-segmented
                            // toneless runs (even via repairs) to repeat them:
                            // one 吃 pick turned 晚餐想吃什麼 into 灣吃安詳吃什麼.
                            let legacyPinned = locked?.entries[spanKey]?.keys.contains(entry.text) ?? false
                            // User overlay: bonus keys on the dictionary span
                            // readings (stable trie path), toneless-joined so
                            // toned learns hit toneless retypes and vice versa.
                            // Only boosts produced candidates — never new paths.
                            // A learned single character pays only when it IS the
                            // whole input: inside a sentence +6 on 設 outweighed the
                            // word 預設 (育設, 與設文字). Sentence-level single chars
                            // are learned by context rules below instead.
                            let learned = end > start || syllables.count == 1
                                ? userLexicon?.bonus(key: spanKey, text: entry.text) ?? 0 : 0
                            let rules = contextRules?[spanKey]?.filter { $0.text == entry.text }
                            let bigrams = contextBigrams?.following(entry.text)
                            for (index, prefix) in prefixes.enumerated() {
                                let pinned = legacyPinned || (locked?.entries[UserLexicon.pinKey(
                                    offset: prefixLengths[index], readings: spanKey)]?.keys
                                    .contains(entry.text) ?? false)
                                let contextual = (rules?.first { $0.previous == previousWords[index] }?.bonus ?? 0)
                                    + (bigrams?[previousWords[index]] ?? 0)
                                var settledHits = 0
                                if let settledUnits {
                                    var offset = prefixLengths[index]
                                    for unit in entry.text.utf16 {
                                        if settledUnits[offset] == unit { settledHits += 1 }
                                        offset += 1
                                    }
                                }
                                let boost = learned + contextual + (pinned ? UserLexicon.pinBonus : 0)
                                    + Double(settledHits) * UserLexicon.pinBonus
                                let score = prefix.score + entry.score - penalty - cost + boost - wordPenalty
                                guard admits(score, at: end + 1) else { continue }
                                add(SentenceCandidate(text: prefix.text + entry.text,
                                    score: score,
                                    repairs: prefix.repairs + repairs + correction,
                                    unresolved: prefix.unresolved,
                                    alignment: prefix.alignment + [WordSpan(
                                        syllables: start..<end + 1,
                                        chars: prefixLengths[index]..<prefixLengths[index] + entry.text.utf16.count)]), at: end + 1)
                            }
                        }
                    }
                }
                states = next.enumerated().sorted {
                    $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 < $1.element.1
                }.prefix(32).map(\.element)
                if states.isEmpty { break }
            }
        }
        return paths[syllables.count].map {
            SentenceCandidate(text: $0.text, score: $0.score, repairs: $0.repairs,
                              unresolved: $0.unresolved, alignment: $0.alignment,
                              syllables: syllables, runs: [0..<syllables.count])
        }
    }
}
