import Foundation

/// English word recognition for mixed Chinese/English typing without a mode
/// switch. `word<TAB>ln p` rows (`script/prepare_lexicon.py`,
/// `.cache/frequencywords/english.tsv`); lowercase a-z words only.
public struct EnglishLexicon {
    public private(set) var scores: [String: Double] = [:]
    /// Words of at least `fuzzyMinLength`, indexed by themselves and by every
    /// one-letter deletion (symmetric-delete): any word within one edit of a
    /// typed string shares a key with it.
    private var deleteIndex: [String: [String]] = [:]
    public static let fuzzyMinLength = 5

    public init(tsv: String) {
        for line in tsv.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            if fields.count == 2, let score = Double(fields[1]) { scores[String(fields[0])] = score }
        }
        for word in scores.keys where word.count >= Self.fuzzyMinLength {
            deleteIndex[word, default: []].append(word)
            for variant in Self.deletions(of: word) { deleteIndex[variant, default: []].append(word) }
        }
    }

    private static func deletions(of word: String) -> Set<String> {
        let chars = Array(word)
        return Set(chars.indices.map { index in
            var copy = chars
            copy.remove(at: index)
            return String(copy)
        })
    }

    /// Optimal-string-alignment distance 1 (substitution, insertion, deletion,
    /// adjacent transposition) test; both strings are short.
    private static func withinOneEdit(_ a: [Character], _ b: [Character]) -> Bool {
        if a == b { return true }
        if abs(a.count - b.count) > 1 { return false }
        if a.count == b.count {
            let diffs = a.indices.filter { a[$0] != b[$0] }
            if diffs.count == 1 { return true }
            return diffs.count == 2 && diffs[1] == diffs[0] + 1
                && a[diffs[0]] == b[diffs[1]] && a[diffs[1]] == b[diffs[0]]
        }
        let (long, short) = a.count > b.count ? (a, b) : (b, a)
        var skip = 0
        while skip < short.count, long[skip] == short[skip] { skip += 1 }
        return Array(long[(skip + 1)...]) == Array(short[skip...])
    }

    /// Exact word (0 edits) or words one edit away from `typed`, best score first.
    public func matches(of typed: String, fuzzy: Bool) -> [(word: String, score: Double, edits: Int)] {
        if let score = scores[typed] { return [(typed, score, 0)] }
        guard fuzzy, typed.count >= Self.fuzzyMinLength - 1 else { return [] }
        var seen = Set<String>()
        var out: [(word: String, score: Double, edits: Int)] = []
        let chars = Array(typed)
        for key in [typed] + Array(Self.deletions(of: typed)) {
            for word in deleteIndex[key] ?? [] where seen.insert(word).inserted {
                if Self.withinOneEdit(chars, Array(word)), let score = scores[word] {
                    out.append((word, score, 1))
                }
            }
        }
        return out.sorted { $0.score > $1.score }
    }

    public func score(of word: String) -> Double? { scores[word] }
    public var isEmpty: Bool { scores.isEmpty }
}

public struct MixedCandidate: Equatable {
    public let sentence: SentenceCandidate
    /// Key ranges (indexes into the typed keys) read as English words.
    public let englishSpans: [Range<Int>]
    /// The English words as rendered (typo-corrected), in span order.
    public let englishWords: [String]
    /// Decoder score plus, per English span, word score minus the switch penalty.
    public let score: Double
    public var text: String { sentence.text }
}

public enum MixedDecoding {
    /// Score points a span must overcome to be read as English instead of
    /// staying Zhuyin. Swept 2026-10-04 (`MixedSweepTests`, 600 pure-Chinese
    /// inputs of 3-6 lexicon words): 0 false switches from 2 up (1% toneless
    /// at 0); recall of clean English words 100% toned / 96% toneless up to
    /// 4, then falls (92% / 90% at 6, 73% at 16). Never raise the risk side
    /// without re-running it.
    public static let defaultSwitchPenalty = 4.0
    public static let defaultMinWordLength = 3
    /// Extra cost per edit when a span is a typo of an English word; the
    /// same order as keyboard edit repair (5-6).
    public static let defaultEnglishEditCost = 6.0
    public static let maxSpanLength = 14
    public static let maxSpans = 8
    public static let maxSpansPerHypothesis = 3
    /// Session wiring. The English reading becomes the top candidate only
    /// when it beats the Chinese reading by this much ON TOP of the switch
    /// penalty; within `suggestWindow` below it, it is listed second.
    public static let autoMargin = 3.0
    public static let suggestWindow = 8.0
    /// Compositions longer than this (keys) skip the mixed pass: bounds the
    /// per-keystroke cost; chunked auto-commit keeps compositions near it.
    public static let maxKeys = 48
    /// Cost of one key left as raw Zhuyin in a live preview (see `mixedPass`).
    public static let rawKeyCost = 5.0
}

/// The live candidate list after the English pass.
public struct MixedApplication {
    public var candidates: [SentenceCandidate]
    /// Texts of the inserted English readings. They cover every typed key, so
    /// the session shows no raw tail with them and keeps them out of
    /// positional pins, the syllable cursor and learning (their run indexes
    /// do not match the composition's own).
    public var completeTexts: Set<String>
    /// The English reading took the top slot (otherwise it is a suggestion).
    public var adopted: Bool
}

extension LexiconDecoder {
    /// Decode a typed key string that may hold English words with no toggle.
    /// Candidate English spans are substrings of consecutive letter keys that
    /// spell a word of `english`; every non-overlapping subset (including the
    /// empty one: pure Chinese) is decoded through the shipping path and the
    /// spans are priced `wordScore - switchPenalty`. Bare keys stay Zhuyin
    /// unless the English reading wins on score, so the result is a
    /// suggestion the caller can show as an alternative.
    public func decodeMixed(keys: [String], english: EnglishLexicon,
                            switchPenalty: Double = MixedDecoding.defaultSwitchPenalty,
                            minWordLength: Int = MixedDecoding.defaultMinWordLength,
                            includePlain: Bool = true,
                            pruneWindow: Double = MixedDecoding.suggestWindow,
                            fuzzyEnglish: Bool = true,
                            englishEditCost: Double = MixedDecoding.defaultEnglishEditCost,
                            liveTail: Bool = false,
                            fuzzy: Bool = true, toneTolerance: Bool = true,
                            userLexicon: UserLexicon? = nil) -> [MixedCandidate] {
        mixedPass(keys: keys, english: english, switchPenalty: switchPenalty, minWordLength: minWordLength,
                  includePlain: includePlain, pruneWindow: pruneWindow, fuzzyEnglish: fuzzyEnglish,
                  englishEditCost: englishEditCost, liveTail: liveTail, fuzzy: fuzzy,
                  toneTolerance: toneTolerance, userLexicon: userLexicon).candidates
    }

    /// `decodeMixed` plus the score of the all-Chinese reading of the same
    /// keys (nil when no span was found, so it was never decoded).
    func mixedPass(keys: [String], english: EnglishLexicon, switchPenalty: Double,
                   minWordLength: Int, includePlain: Bool, pruneWindow: Double, fuzzyEnglish: Bool,
                   englishEditCost: Double, liveTail: Bool, fuzzy: Bool, toneTolerance: Bool,
                   userLexicon: UserLexicon?) -> (candidates: [MixedCandidate], plainScore: Double?) {
        guard !keys.isEmpty else { return ([], nil) }
        // A letter-like key is a bare Zhuyin-position letter, or a letter already
        // typed as latin (Shift-hold capital): "Python" is L:P + bare y t h o n.
        func letter(_ key: String) -> (char: Character, latin: Bool)? {
            if key.count == 1, let c = key.first, c.isASCII, c.isLetter, c.isLowercase { return (c, false) }
            if Composition.isLatinKey(key), let c = Composition.latinChar(key).first,
               Composition.latinChar(key).count == 1, c.isASCII, c.isLetter { return (Character(c.lowercased()), true) }
            return nil
        }
        var spans: [(range: Range<Int>, word: String, score: Double)] = []
        var start = 0
        while start < keys.count {
            guard letter(keys[start]) != nil else { start += 1; continue }
            var end = start
            while end < keys.count, letter(keys[end]) != nil { end += 1 }
            for from in start..<end where from + minWordLength <= end {
                for to in (from + minWordLength)...min(end, from + MixedDecoding.maxSpanLength) {
                    // Latin keys only lead a span (a capital), and at least one key is bare.
                    var seenBare = false, valid = true
                    for index in from..<to {
                        if letter(keys[index])!.latin { if seenBare { valid = false; break } } else { seenBare = true }
                    }
                    guard valid, seenBare else { continue }
                    let typed = String((from..<to).map { letter(keys[$0])!.char })
                    let capital = Composition.isLatinKey(keys[from])
                        && Composition.latinChar(keys[from]).first?.isUppercase == true
                    for match in english.matches(of: typed, fuzzy: fuzzyEnglish)
                    where match.word.count >= minWordLength {
                        // A different extra letter right after a whole word is
                        // most likely the next Chinese syllable starting, not a
                        // typo; swallowing it would drop that key from the text.
                        // A doubled letter (pythonn) still counts as a slip.
                        if match.edits == 1, typed.count == match.word.count + 1, typed.hasPrefix(match.word),
                           typed.last != typed.dropLast().last { continue }
                        let word = capital ? match.word.prefix(1).uppercased() + match.word.dropFirst() : match.word
                        spans.append((from..<to, word, match.score - englishEditCost * Double(match.edits)))
                    }
                }
            }
            start = end
        }
        spans.sort { $0.score == $1.score ? $0.range.lowerBound < $1.range.lowerBound : $0.score > $1.score }
        spans = Array(spans.prefix(MixedDecoding.maxSpans))

        // Each hypothesis is decoded once. Pruning: a span is scored alone
        // first and kept only when that reading is within `pruneWindow` of
        // the all-Chinese one; the subsets worth combining are then few.
        var memo: [[Int]: [MixedCandidate]] = [:]
        func hypothesis(_ subset: [Int]) -> [MixedCandidate] {
            if let hit = memo[subset] { return hit }
            let chosen = subset.map { spans[$0] }.sorted { $0.range.lowerBound < $1.range.lowerBound }
            var composition = Composition()
            for (index, key) in keys.enumerated() {
                if let span = chosen.first(where: { $0.range.contains(index) }) {
                    // A typo'd span renders the corrected word, once, at its start.
                    if index == span.range.lowerBound {
                        for char in span.word { composition.appendLatin(String(char)) }
                    }
                } else if key == " " {
                    // Literal separator after English, first tone after Zhuyin.
                    composition.appendSpace()
                } else if Composition.isLatinKey(key) {
                    composition.appendLatin(Composition.latinChar(key))
                } else if Punctuation.literals.contains(key) {
                    composition.appendLiteral(key)
                } else {
                    composition.append(key)
                }
            }
            // Live (the IME preview): the syllable still being typed stays raw
            // and is part of the text, so what shows is what commits. Raw keys
            // are not free, or "everything left as raw Zhuyin" would beat any
            // reading: each costs `rawKeyCost`, the same order as an edit
            // repair. Finished phrases (`liveTail` off) decode every key.
            let pending = composition.parsed.pending
            let cut = liveTail ? livePendingCut(pending, toneTolerance: toneTolerance) : pending.count
            let tail = pending.dropFirst(cut).compactMap { ZhuyinKeyboard.symbols[$0] }.joined()
            let decoded = decodeSegments(composition.segments, pendingKeys: Array(pending.prefix(cut)),
                                         fuzzy: fuzzy, toneTolerance: toneTolerance, userLexicon: userLexicon)
            let extra = chosen.reduce(0.0) { $0 + $1.score - switchPenalty }
                - MixedDecoding.rawKeyCost * Double(tail.count)
            let result = decoded.prefix(2).map { sentence -> MixedCandidate in
                let shown = tail.isEmpty ? sentence : SentenceCandidate(
                    text: sentence.text + tail, score: sentence.score, repairs: sentence.repairs,
                    unresolved: sentence.unresolved, alignment: sentence.alignment,
                    syllables: sentence.syllables, runs: sentence.runs)
                return MixedCandidate(sentence: shown, englishSpans: chosen.map(\.range),
                                      englishWords: chosen.map(\.word), score: sentence.score + extra)
            }
            memo[subset] = result
            return result
        }
        guard !spans.isEmpty else { return (includePlain ? hypothesis([]) : [], nil) }
        let plainScore = hypothesis([]).first?.score ?? -.infinity
        let survivors = spans.indices.filter { (hypothesis([$0]).first?.score ?? -.infinity) > plainScore - pruneWindow }
        var subsets: [[Int]] = includePlain ? [[]] : []
        func extend(_ chosen: [Int], from index: Int) {
            for next in index..<survivors.count where chosen.count < MixedDecoding.maxSpansPerHypothesis {
                let candidate = survivors[next]
                if chosen.contains(where: { spans[$0].range.overlaps(spans[candidate].range) }) { continue }
                subsets.append(chosen + [candidate])
                extend(chosen + [candidate], from: next + 1)
            }
        }
        extend([], from: 0)

        var best: [String: MixedCandidate] = [:]
        for subset in subsets {
            for candidate in hypothesis(subset) {
                if let existing = best[candidate.text], existing.score >= candidate.score { continue }
                best[candidate.text] = candidate
            }
        }
        return (best.values.sorted { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
            .prefix(16).map { $0 }, plainScore)
    }
}

extension LexiconDecoder {
    /// Add the English reading to a live preview when the typed keys support
    /// it. Nil = leave `live` alone. The pass is pruned to where it can pay:
    /// a run of >= `minWordLength` letter keys (bare, or a leading Shift
    /// capital) with at least one bare, and at least one candidate span
    /// that survives scoring alone against the Chinese reading. (A gate on
    /// "the Chinese reading shows trouble" was tried and dropped: you / for
    /// spell valid Chinese syllable pairs, so clean Chinese readings of
    /// English words are common and the gate cost 18 points of recall.)
    public func applyEnglish(to live: LivePreview, composition: Composition, english: EnglishLexicon,
                             fuzzy: Bool = true, toneTolerance: Bool = true,
                             userLexicon: UserLexicon? = nil,
                             minWordLength: Int = MixedDecoding.defaultMinWordLength,
                             autoMargin: Double = MixedDecoding.autoMargin,
                             suggestWindow: Double = MixedDecoding.suggestWindow) -> MixedApplication? {
        let keys = composition.rawKeys
        guard !english.isEmpty, keys.count >= minWordLength, keys.count <= MixedDecoding.maxKeys,
              !live.candidates.isEmpty else { return nil }
        // Letters typed bare, or as a leading Shift capital (latin key); the
        // rest of the composition (punctuation, earlier latin, tones, spaces)
        // is carried through unchanged.
        var run = 0, longest = 0, bareInRun = 0
        var bestHasBare = false
        for key in keys {
            let bare = key.count == 1 && key.first.map { $0.isASCII && $0.isLetter } == true
            let latin = Composition.isLatinKey(key) && Composition.latinChar(key).count == 1
            if bare || latin {
                run += 1
                if bare { bareInRun += 1 }
                if run > longest { longest = run; bestHasBare = bareInRun > 0 }
            } else { run = 0; bareInRun = 0 }
        }
        guard longest >= minWordLength, bestHasBare else { return nil }
        // Margin against the pin-free Chinese reading (the pass's own plain
        // decode): live scores carry pin bonuses.
        let pass = mixedPass(keys: keys, english: english, switchPenalty: MixedDecoding.defaultSwitchPenalty,
                             minWordLength: minWordLength, includePlain: false, pruneWindow: suggestWindow,
                             fuzzyEnglish: true, englishEditCost: MixedDecoding.defaultEnglishEditCost,
                             liveTail: true, fuzzy: fuzzy, toneTolerance: toneTolerance, userLexicon: userLexicon)
        let mixed = pass.candidates
        guard let best = mixed.first, let plain = pass.plainScore else { return nil }
        let margin = best.score - plain
        guard margin >= -suggestWindow else { return nil }
        let adopted = margin >= autoMargin
        var inserted = [best.sentence]
        if let second = mixed.dropFirst().first, best.score - second.score < suggestWindow {
            inserted.append(second.sentence)
        }
        let rest = live.candidates.filter { candidate in !inserted.contains { $0.text == candidate.text } }
        let ordered = adopted ? inserted + rest : Array(rest.prefix(1)) + inserted + Array(rest.dropFirst())
        return MixedApplication(candidates: ordered, completeTexts: Set(inserted.map(\.text)), adopted: adopted)
    }
}
