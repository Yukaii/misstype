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
                            fuzzyEnglish: Bool = true,
                            englishEditCost: Double = MixedDecoding.defaultEnglishEditCost,
                            fuzzy: Bool = true, toneTolerance: Bool = true,
                            userLexicon: UserLexicon? = nil) -> [MixedCandidate] {
        guard !keys.isEmpty else { return [] }
        func isLetter(_ key: String) -> Bool {
            key.count == 1 && key.first.map { $0.isASCII && $0.isLetter && $0.isLowercase } == true
        }
        var spans: [(range: Range<Int>, word: String, score: Double)] = []
        var start = 0
        while start < keys.count {
            guard isLetter(keys[start]) else { start += 1; continue }
            var end = start
            while end < keys.count, isLetter(keys[end]) { end += 1 }
            for from in start..<end where from + minWordLength <= end {
                for to in (from + minWordLength)...min(end, from + MixedDecoding.maxSpanLength) {
                    for match in english.matches(of: keys[from..<to].joined(), fuzzy: fuzzyEnglish)
                    where match.word.count >= minWordLength {
                        spans.append((from..<to, match.word, match.score - englishEditCost * Double(match.edits)))
                    }
                }
            }
            start = end
        }
        spans.sort { $0.score == $1.score ? $0.range.lowerBound < $1.range.lowerBound : $0.score > $1.score }
        spans = Array(spans.prefix(MixedDecoding.maxSpans))

        var subsets: [[Int]] = [[]]
        func extend(_ chosen: [Int], from index: Int) {
            for next in index..<spans.count where chosen.count < MixedDecoding.maxSpansPerHypothesis {
                if chosen.contains(where: { spans[$0].range.overlaps(spans[next].range) }) { continue }
                subsets.append(chosen + [next])
                extend(chosen + [next], from: next + 1)
            }
        }
        extend([], from: 0)

        var best: [String: MixedCandidate] = [:]
        for subset in subsets {
            let chosen = subset.map { spans[$0] }.sorted { $0.range.lowerBound < $1.range.lowerBound }
            var composition = Composition()
            for (index, key) in keys.enumerated() {
                if let span = chosen.first(where: { $0.range.contains(index) }) {
                    // A typo'd span renders the corrected word, once, at its start.
                    if index == span.range.lowerBound {
                        for letter in span.word { composition.appendLatin(String(letter)) }
                    }
                } else {
                    composition.append(key)
                }
            }
            let decoded = decodeSegments(composition.segments, pendingKeys: composition.parsed.pending,
                                         fuzzy: fuzzy, toneTolerance: toneTolerance, userLexicon: userLexicon)
            let extra = chosen.reduce(0.0) { $0 + $1.score - switchPenalty }
            for sentence in decoded.prefix(2) {
                let candidate = MixedCandidate(sentence: sentence, englishSpans: chosen.map(\.range), englishWords: chosen.map(\.word),
                                               score: sentence.score + extra)
                if let existing = best[sentence.text], existing.score >= candidate.score { continue }
                best[sentence.text] = candidate
            }
        }
        return best.values.sorted { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
            .prefix(16).map { $0 }
    }
}
