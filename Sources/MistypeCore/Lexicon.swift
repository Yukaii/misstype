import Foundation

public struct SentenceCandidate: Equatable {
    public let text: String
    public let score: Double
    public let repairs: Int
    public let unresolved: Int
}

public final class LexiconDecoder {
    private final class Node {
        var children: [String: Node] = [:]
        var entries: [(text: String, score: Double)] = []
    }
    private let root = Node()
    private var readings: Set<String> = []
    private var toneless: [String: Set<String>] = [:]
    public private(set) var entryCount = 0

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
            node.entries = Array(node.entries.prefix(3))
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
        // Tiers: exact 0, toneless 0.5, tone-mismatch 2.0, transpose 4,
        // substitute/phonetic 5, insert/delete 6.
        var scored: [String: (cost: Double, correction: Int)] = [:]
        func add(_ reading: String, _ cost: Double, _ correction: Int) {
            if let prev = scored[reading], prev.cost <= cost { return }
            scored[reading] = (cost, correction)
        }
        if let tone = syllable.tone, tone != "" {
            // Tone is a soft hint, not a hard filter: users mistype or
            // misplace tones, so the same base in other tones stays viable
            // at a penalty between toneless (0.5) and fuzzy repair (5).
            if readings.contains(reading) { add(reading, 0, 0) }
            if toneTolerance, let variants = toneless[Self.withoutTone(reading)] {
                for variant in variants where variant != reading { add(variant, 2.0, 1) }
            }
        }
        // Toneless (nil) leaves the tone fully to the engine. A space
        // terminator ("") is stronger: an exact first-tone reading ranks at
        // cost 0, other tones stay viable below it — so explicit first tone
        // wins, while toneless-with-spaces still decodes (bases without an
        // exact first-tone form fall through to variants alone).
        if syllable.tone == nil {
            if let variants = toneless[Self.withoutTone(reading)] {
                for variant in variants { add(variant, 0.5, 0) }
            }
        } else if syllable.tone == "" {
            if readings.contains(reading) { add(reading, 0, 0) }
            if toneTolerance, let variants = toneless[Self.withoutTone(reading)] {
                for variant in variants where variant != reading { add(variant, 0.5, 0) }
            }
        }
        if fuzzy {
            // Auto-repair: adjacent transposition (key order slips), neighbor
            // and phonetic-confusion substitution, deletion of an extra key,
            // insertion of a missing key.
            let tonelessProbe = syllable.tone == nil || syllable.tone == ""
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
    /// slices rank by their cheapest option cost (clean 0–0.5, tone-mismatch
    /// 2.0, transpose 4, substitute 5, insert/delete 6), so one corrupt
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
    /// Split a tone-terminated run that is not viable as one syllable: the tone
    /// belongs to the trailing piece (the syllable just finished), the lead is
    /// segmented tonelessly. Without this, one mid-sentence tone key fuses the
    /// whole pending run into a single giant syllable and everything falls
    /// back to raw Bopomofo. Falls back to the original syllable (fuzzy rescue
    /// in decode) when no clean split exists.
    private func repairComplete(_ syllable: Syllable, toneTolerance: Bool = true) -> [[Syllable]] {
        if !alternatives(syllable, fuzzy: false).isEmpty { return [[syllable]] }
        guard syllable.keys.count > 1 else { return [] }
        var out: [[Syllable]] = []
        for tailLen in 1...min(Self.maxSyllableKeys, syllable.keys.count - 1) {
            let tail = Syllable(keys: Array(syllable.keys.suffix(tailLen)), tone: syllable.tone)
            guard !alternatives(tail, fuzzy: false, toneTolerance: toneTolerance).isEmpty else { continue }
            let leadKeys = Array(syllable.keys.prefix(syllable.keys.count - tailLen))
            for lead in segmentations(of: leadKeys, fuzzy: false, toneTolerance: toneTolerance).prefix(6) {
                out.append(lead + [tail])
                if out.count >= 12 { return out }
            }
        }
        return out
    }
    /// Decode tone-terminated syllables plus an unsegmented pending key run.
    /// Covers all three styles: toneless-continuous, space-separated, toned.
    /// Complete runs fused by a mid-sentence tone key are repaired first.
    /// Falls back to the legacy single-syllable reading
    /// (surfaced as unresolved) when nothing segments.
    public func decodeComposition(complete: [Syllable], pendingKeys: [String], fuzzy: Bool = true, toneTolerance: Bool = true, userLexicon: UserLexicon? = nil) -> [SentenceCandidate] {
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
                return decode(complete + [Syllable(keys: pendingKeys, tone: nil)], fuzzy: fuzzy, toneTolerance: toneTolerance, userLexicon: userLexicon)
            }
        }
        var merged: [SentenceCandidate] = []
        func merge(_ syllables: [Syllable], budget: inout Int) {
            for candidate in decode(syllables, fuzzy: fuzzy, toneTolerance: toneTolerance, userLexicon: userLexicon) {
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
    public func decodeSegments(_ segments: [Composition.Segment], pendingKeys: [String], fuzzy: Bool = true, toneTolerance: Bool = true, userLexicon: UserLexicon? = nil) -> [SentenceCandidate] {
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
                                         userLexicon: userLexicon)
            runTops.append(tops.isEmpty ? [empty] : tops)
        }
        func render(_ picks: [SentenceCandidate]) -> SentenceCandidate {
            var text = ""
            var score = 0.0
            var repairs = 0
            var unresolved = 0
            for (index, pick) in picks.enumerated() {
                text += pick.text
                score += pick.score
                repairs += pick.repairs
                unresolved += pick.unresolved
                if index < seps.count { text += seps[index] }
            }
            return SentenceCandidate(text: text, score: score, repairs: repairs, unresolved: unresolved)
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

    public func decode(_ syllables: [Syllable], fuzzy: Bool = true, toneTolerance: Bool = true, userLexicon: UserLexicon? = nil) -> [SentenceCandidate] {        guard !syllables.isEmpty else { return [] }
        let options = syllables.map { alternatives($0, fuzzy: fuzzy, toneTolerance: toneTolerance) }
        var paths = Array(repeating: [SentenceCandidate](), count: syllables.count + 1)
        paths[0] = [SentenceCandidate(text: "", score: 0, repairs: 0, unresolved: 0)]
        func add(_ candidate: SentenceCandidate, at index: Int) {
            if let same = paths[index].firstIndex(where: { $0.text == candidate.text }) {
                if paths[index][same].score >= candidate.score { return }
                paths[index].remove(at: same)
            }
            paths[index].append(candidate)
            paths[index].sort { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
            paths[index] = Array(paths[index].prefix(16))
        }
        for start in syllables.indices {
            guard !paths[start].isEmpty else { continue }
            let prefixes = paths[start]
            for prefix in prefixes {
                add(SentenceCandidate(text: prefix.text + syllables[start].reading,
                    score: prefix.score - 100, repairs: prefix.repairs,
                    unresolved: prefix.unresolved + 1), at: start + 1)
            }
            var states: [(node: Node, penalty: Double, repairs: Int, readings: [String])] = [(root, 0, 0, [])]
            for end in start..<min(syllables.count, start + 8) {
                var next: [(node: Node, penalty: Double, repairs: Int, readings: [String])] = []
                for (node, penalty, repairs, readings) in states {
                    for (reading, cost, correction) in options[end] {
                        guard let child = node.children[reading] else { continue }
                        let span = readings + [reading]
                        next.append((child, penalty + cost, repairs + correction, span))
                        for entry in child.entries {
                            let spanKey = UserLexicon.key(forReadings: span)
                            // User overlay: bonus keys on the dictionary span
                            // readings (stable trie path), toneless-joined so
                            // toned learns hit toneless retypes and vice versa.
                            // Only boosts produced candidates — never new paths.
                            let boost = userLexicon?.bonus(key: spanKey,
                                text: entry.text) ?? 0
                            for prefix in prefixes {
                                add(SentenceCandidate(text: prefix.text + entry.text,
                                    score: prefix.score + entry.score - penalty - cost + boost,
                                    repairs: prefix.repairs + repairs + correction,
                                    unresolved: prefix.unresolved), at: end + 1)
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
        return paths[syllables.count]
    }
}
