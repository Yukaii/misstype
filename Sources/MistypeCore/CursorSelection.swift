import Foundation

/// One pickable word at the syllable cursor. `span` is the syllable range
/// the word would occupy; picking pins exactly that range, so the word may
/// cross the current top path's word boundaries.
public struct CursorOption: Equatable {
    public let text: String
    public let span: Range<Int>
    public let score: Double
    public init(text: String, span: Range<Int>, score: Double) {
        self.text = text
        self.span = span
        self.score = score
    }
}

extension LexiconDecoder {
    /// Every word covering syllable `cursor`, any length (McBopomofo-style):
    /// longest spans first, then earlier starts, each span best-first.
    /// Replaces the aligned-word list, which only offered the top path's own
    /// segmentation — a fix that needs a different word boundary (大|對 vs
    /// 打對) was unreachable. Multi-syllable spans keep their best
    /// `perSpan` words so long idioms never bury the single-char homophone
    /// browser at the end.
    /// `within` confines words to one Zhuyin run (words never cross
    /// punctuation or latin; see `SentenceCandidate.run(containing:)`).
    public func cursorOptions(_ syllables: [Syllable], at cursor: Int,
                              within: Range<Int>? = nil,
                              fuzzy: Bool = true, toneTolerance: Bool = true,
                              perSpan: Int = 4) -> [CursorOption] {
        let bounds = (within ?? 0..<syllables.count).clamped(to: 0..<syllables.count)
        guard bounds.contains(cursor) else { return [] }
        var out: [CursorOption] = []
        for length in stride(from: min(8, bounds.count), through: 1, by: -1) {
            let first = max(bounds.lowerBound, cursor - length + 1)
            let last = min(cursor, bounds.upperBound - length)
            guard first <= last else { continue }
            for start in first...last {
                let span = start..<start + length
                let words = segmentOptions(syllables, span: span, fuzzy: fuzzy,
                                           toneTolerance: toneTolerance)
                for word in words.prefix(length == 1 ? words.count : perSpan) {
                    out.append(CursorOption(text: word.text, span: span, score: word.score))
                }
            }
        }
        return out
    }
}

extension SentenceCandidate {
    /// Syllable range of the Zhuyin run holding `syllable`. Runs are split
    /// where consecutive words leave a character gap (a separator was
    /// rendered between them) — the same boundary decodeSegments enforces.
    public func run(containing syllable: Int) -> Range<Int>? {
        guard let index = alignment.firstIndex(where: { $0.syllables.contains(syllable) }) else { return nil }
        var first = index
        while first > 0, alignment[first - 1].chars.upperBound == alignment[first].chars.lowerBound {
            first -= 1
        }
        var last = index
        while last + 1 < alignment.count, alignment[last].chars.upperBound == alignment[last + 1].chars.lowerBound {
            last += 1
        }
        return alignment[first].syllables.lowerBound..<alignment[last].syllables.upperBound
    }

    /// UTF-16 offset of `syllable`'s first character: exact inside 1:1
    /// words, else the start of the word holding it.
    public func charOffset(ofSyllable syllable: Int) -> Int? {
        guard let word = alignment.first(where: { $0.syllables.contains(syllable) }) else { return nil }
        guard word.chars.count == word.syllables.count else { return word.chars.lowerBound }
        return word.chars.lowerBound + (syllable - word.syllables.lowerBound)
    }
}

extension UserLexicon {
    /// Session-pin `option` over the displayed `top`, changing nothing but
    /// the option's own span. Older pinned words that overlap it are split:
    /// their characters outside the span stay pinned one syllable each, so
    /// picking 錢包 after 帶錢 keeps 帶 instead of snapping back to 大 (two
    /// overlapping pins at pinBonus cannot both win, and the loser used to
    /// revert). Pins are reading-keyed, so a split pin also covers identical
    /// readings elsewhere in the session — acceptable for session scope.
    public mutating func pin(_ option: CursorOption, over top: SentenceCandidate) {
        let syllables = top.syllables
        guard option.span.lowerBound >= 0, option.span.upperBound <= syllables.count else { return }
        let units = Array(top.text.utf16)
        for word in top.alignment where word.syllables.overlaps(option.span)
            && word.syllables.upperBound <= syllables.count && word.chars.upperBound <= units.count {
            let key = UserLexicon.key(for: Array(syllables[word.syllables]))
            let text = String(decoding: units[word.chars], as: UTF16.self)
            guard entries[key]?[text] != nil else { continue }
            entries.removeValue(forKey: key)
            guard word.chars.count == word.syllables.count else { continue }
            for (offset, index) in word.syllables.enumerated() where !option.span.contains(index) {
                let unit = word.chars.lowerBound + offset
                let char = String(decoding: units[unit..<unit + 1], as: UTF16.self)
                entries[UserLexicon.key(for: [syllables[index]])] =
                    [char: Record(count: 1, updatedAt: 0)]
            }
        }
        entries[UserLexicon.key(for: Array(syllables[option.span]))] =
            [option.text: Record(count: 1, updatedAt: 0)]
    }
}

/// Deterministic selection replay: how many cursor picks turn the offline
/// top-1 into `expected`? Measures the candidate model, not a user. Each
/// step moves to the first wrong character, takes the longest option that
/// matches `expected` there, pins it, and re-decodes. Needs a 1:1
/// syllable↔character alignment (pure Zhuyin runs); anything else is nil.
public enum CursorReplay {
    public enum Model: String {
        /// Pre-2026-09-27 IME: the top path's word at the cursor, or the
        /// single syllable when the cursor sits mid-word (both offered, so
        /// the baseline gets its best case).
        case aligned
        /// Every word starting at the cursor (`cursorOptions`).
        case startAtCursor
    }
    public struct Outcome: Equatable {
        /// Picks needed; nil when the expected text is unreachable.
        public let picks: Int?
        /// 0-based list position of each pick (panel scanning cost).
        public let ranks: [Int]
    }

    /// Decodes exactly like the IME preview (terminated segments, no
    /// pending tail) and reads syllables from the top candidate.
    public static func run(_ decoder: LexiconDecoder, segments: [Composition.Segment],
                           expected: String, model: Model,
                           fuzzy: Bool = true, toneTolerance: Bool = true,
                           maxPicks: Int = 6) -> Outcome {
        let target = Array(expected)
        var pins = UserLexicon()
        var ranks: [Int] = []
        for _ in 0...maxPicks {
            guard let top = decoder.decodeSegments(segments, pendingKeys: [], fuzzy: fuzzy,
                                                   toneTolerance: toneTolerance,
                                                   locked: pins.isEmpty ? nil : pins).first else { break }
            let syllables = top.syllables
            let text = Array(top.text)
            if text == target { return Outcome(picks: ranks.count, ranks: ranks) }
            guard ranks.count < maxPicks, top.unresolved == 0,
                  text.count == syllables.count, target.count == syllables.count,
                  let c = text.indices.first(where: { text[$0] != target[$0] }) else { break }
            let options: [CursorOption]
            switch model {
            case .startAtCursor:
                options = decoder.cursorOptions(syllables, at: c, within: top.run(containing: c),
                                                fuzzy: fuzzy, toneTolerance: toneTolerance)
            case .aligned:
                var aligned: [CursorOption] = []
                if let word = top.alignment.first(where: { $0.syllables.contains(c) }) {
                    aligned += decoder.segmentOptions(syllables, span: word.syllables, fuzzy: fuzzy,
                                                      toneTolerance: toneTolerance)
                        .map { CursorOption(text: $0.text, span: word.syllables, score: $0.score) }
                }
                if aligned.first?.span != c..<c + 1 {
                    aligned += decoder.segmentOptions(syllables, span: c..<c + 1, fuzzy: fuzzy,
                                                      toneTolerance: toneTolerance)
                        .map { CursorOption(text: $0.text, span: c..<c + 1, score: $0.score) }
                }
                options = aligned
            }
            let matches = options.indices.filter { index in
                let option = options[index]
                return String(target[option.span]) == option.text && option.span.contains(c)
            }
            guard let pick = matches.max(by: { options[$0].span.count < options[$1].span.count
                || (options[$0].span.count == options[$1].span.count && $0 > $1) }) else { break }
            pins.pin(options[pick], over: top)
            ranks.append(pick)
        }
        return Outcome(picks: nil, ranks: ranks)
    }
}
