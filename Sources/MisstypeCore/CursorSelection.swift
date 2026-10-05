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

/// Candidate selection keys (default home row `asdfghjkl;`). They are also
/// Zhuyin keys, so they select only in selection mode (entered with
/// Down/Tab or the syllable cursor); elsewhere they type phonetics.
public enum SelectionKeys {
    public static let defaultKeys = "asdfghjkl;"
    /// Candidates per page: default and the range a preference may pick.
    public static let defaultPageSize = 8
    public static let pageSizes = 4...10
    public static func clampPageSize(_ size: Int) -> Int {
        min(max(size, pageSizes.lowerBound), pageSizes.upperBound)
    }
    /// Visible page slot for a key label, or nil when the label is not a
    /// selection key. Only the first `pageSize` keys address the page.
    public static func slot(forLabel label: String, keys: String, pageSize: Int = 8) -> Int? {
        let labels = Array(keys).prefix(pageSize).map(String.init)
        return labels.firstIndex(of: label)
    }
    /// Preferences input -> usable keys: lowercased, distinct, only keys the
    /// keyboard map knows (never space), capped at one page; empty -> default.
    public static func sanitize(_ input: String, pageSize: Int = 8) -> String {
        let known = Set(ZhuyinKeyboard.symbols.keys).union(ZhuyinKeyboard.tones.keys).subtracting([" "])
        var seen = Set<String>()
        let keys = input.lowercased().map(String.init)
            .filter { known.contains($0) && seen.insert($0).inserted }
            .prefix(pageSize)
        return keys.isEmpty ? String(defaultKeys.prefix(pageSize)) : keys.joined()
    }
    /// Labels shown beside the visible rows.
    public static func labels(keys: String, pageSize: Int = 8) -> [String] {
        Array(keys).prefix(pageSize).map(String.init)
    }
}

/// Keys that turn candidate pages in selection mode, on top of PageUp /
/// PageDown. They type normally outside it, and a selection key wins when
/// the two overlap.
public enum PageKeys: String, CaseIterable, Sendable {
    /// `-` / `=` (the Rime/Pinyin convention; the default).
    case minusEqual
    /// `,` / `.`
    case commaPeriod
    /// `[` / `]`
    case brackets
    /// PageUp / PageDown only.
    case none

    /// (previous page, next page) key labels.
    public var labels: (previous: String, next: String)? {
        switch self {
        case .minusEqual: return ("-", "=")
        case .commaPeriod: return (",", ".")
        case .brackets: return ("[", "]")
        case .none: return nil
        }
    }

    /// Paging direction for a key label: true = next page, nil = not a page key.
    public func direction(forLabel label: String) -> Bool? {
        guard let labels else { return nil }
        if label == labels.next { return true }
        if label == labels.previous { return false }
        return nil
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
    /// Syllable range of the Zhuyin run holding `syllable` (decodeSegments
    /// run boundaries: words never cross punctuation or latin).
    public func run(containing syllable: Int) -> Range<Int>? {
        runs.first(where: { $0.contains(syllable) })
    }

    /// Positional session-pin key for the word starting at `syllable` and
    /// covering `span`: run index + run-local UTF-16 offset + readings.
    public func pinKey(forSpan span: Range<Int>) -> String? {
        guard let run = runs.firstIndex(where: { $0.contains(span.lowerBound) }),
              span.upperBound <= runs[run].upperBound,
              let start = charOffset(ofSyllable: span.lowerBound),
              let runStart = charOffset(ofSyllable: runs[run].lowerBound) else { return nil }
        return UserLexicon.pinKey(run: run, offset: start - runStart,
                                  readings: UserLexicon.key(for: Array(syllables[span])))
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
    /// Positional session-pin key: "run#offset@readings". decodeSegments
    /// hands each run its own pins as "offset@readings" (`pins(forRun:)`);
    /// decode() matches the run-local UTF-16 offset where a word starts.
    public static func pinKey(run: Int, offset: Int, readings: String) -> String {
        "\(run)#" + pinKey(offset: offset, readings: readings)
    }
    public static func pinKey(offset: Int, readings: String) -> String {
        "\(offset)@\(readings)"
    }

    /// Pins visible to run `run`: its positional pins with the run prefix
    /// stripped, plus legacy reading-only pins (CLI --lock). Nil when empty.
    public func pins(forRun run: Int) -> UserLexicon? {
        let prefix = "\(run)#"
        var out = UserLexicon()
        for (key, texts) in entries {
            if key.hasPrefix(prefix) {
                out.entries[String(key.dropFirst(prefix.count))] = texts
            } else if !key.contains("#") {
                out.entries[key] = texts
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Whether any pin (legacy reading-only or positional, any offset) names
    /// `text` for `readings`. A cheap superset test; the decoder still
    /// checks the exact position before paying the bonus.
    public func hasPin(readings: String, text: String) -> Bool {
        if entries[readings]?.keys.contains(text) ?? false { return true }
        let suffix = "@" + readings
        return entries.contains { $0.key.hasSuffix(suffix) && $0.value.keys.contains(text) }
    }

    /// Session-pin `option` over the displayed `top`, changing nothing but
    /// the option's own span. Pins are positional, so they hold only where
    /// they were picked. Older pinned words that overlap the span are split:
    /// their characters outside it stay pinned one syllable each, so picking
    /// 錢包 after 帶錢 keeps 帶 instead of snapping back to 大 (two
    /// overlapping pins cannot both win, and the loser used to revert).
    public mutating func pin(_ option: CursorOption, over top: SentenceCandidate) {
        let syllables = top.syllables
        guard option.span.lowerBound >= 0, option.span.upperBound <= syllables.count,
              let optionKey = top.pinKey(forSpan: option.span) else { return }
        let units = Array(top.text.utf16)
        for word in top.alignment where word.syllables.overlaps(option.span)
            && word.syllables.upperBound <= syllables.count && word.chars.upperBound <= units.count {
            let text = String(decoding: units[word.chars], as: UTF16.self)
            guard let key = top.pinKey(forSpan: word.syllables), entries[key]?[text] != nil else { continue }
            entries.removeValue(forKey: key)
            guard word.chars.count == word.syllables.count else { continue }
            for (offset, index) in word.syllables.enumerated() where !option.span.contains(index) {
                let unit = word.chars.lowerBound + offset
                guard let singleKey = top.pinKey(forSpan: index..<index + 1) else { continue }
                entries[singleKey] = [String(decoding: units[unit..<unit + 1], as: UTF16.self):
                                        Record(count: 1, updatedAt: 0)]
            }
        }
        entries[optionKey] = [option.text: Record(count: 1, updatedAt: 0)]
    }
}

extension UserLexicon {
    /// Word-level learning for one learning-grade commit. The old rule
    /// recorded the whole composition's readings -> the whole text, but the
    /// decoder only boosts dictionary words, so a learned sentence never
    /// changed anything (verified: 測試一下會不會打對 learned x3 still
    /// decoded 大對; learning the word 打對 fixed it and every other
    /// sentence with ㄉㄚㄉㄨㄟ). Now the unit is the word:
    /// - input that is one word: learned as before (homophone browsing);
    /// - otherwise words of 2+ syllables the user chose — a cursor pin still
    ///   standing at commit, or a word differing from `baseline` (the
    ///   default top-1) after a whole-sentence pick.
    /// Single characters inside sentences are learned only in context —
    /// keyed on the word before them in the same run (`contextKey`) — since
    /// a global 再 bonus would bury the far more common 在. A single char
    /// with no previous word in its run is not learned.
    public static func learnedWords(committed: SentenceCandidate, pins: UserLexicon,
                                    baseline: SentenceCandidate?) -> [(key: String, text: String)] {
        let units = Array(committed.text.utf16)
        let syllables = committed.syllables
        guard committed.unresolved == 0, let end = committed.alignment.last?.syllables.upperBound,
              end == syllables.count else { return [] }
        let whole = committed.alignment.count == 1
        let baseUnits = baseline.map { Array($0.text.utf16) }
        var out: [(key: String, text: String)] = []
        for word in committed.alignment where word.chars.upperBound <= units.count {
            let text = String(decoding: units[word.chars], as: UTF16.self)
            let pinned = committed.pinKey(forSpan: word.syllables).map { pins.entries[$0]?[text] != nil } ?? false
            var changed = false
            if let base = baseUnits, base.count == units.count {
                changed = String(decoding: base[word.chars], as: UTF16.self) != text
            }
            let readings = UserLexicon.key(for: Array(syllables[word.syllables]))
            if whole || (word.syllables.count >= 2 && (pinned || changed)) {
                out.append((readings, text))
            } else if pinned || changed, let previous = committed.alignment.last(where: {
                $0.syllables.upperBound == word.syllables.lowerBound && $0.chars.upperBound == word.chars.lowerBound
            }), committed.run(containing: previous.syllables.lowerBound) == committed.run(containing: word.syllables.lowerBound),
              previous.chars.upperBound <= units.count {
                let before = String(decoding: units[previous.chars], as: UTF16.self)
                out.append((UserLexicon.contextKey(previous: before, readings: readings), text))
            }
        }
        return out
    }
}

extension UserLexicon {
    /// Keep a whole-sentence pick alive while typing continues. The pick was
    /// matched back by text prefix, but live conversion re-segments the
    /// growing tail, so the prefix can stop matching and the pick silently
    /// dropped. Pin (positionally) the words of `picked` that differ from
    /// `baseline` — every word when the two do not line up char for char.
    public mutating func pinDifferences(of picked: SentenceCandidate, from baseline: SentenceCandidate) {
        let units = Array(picked.text.utf16), base = Array(baseline.text.utf16)
        for word in picked.alignment where word.chars.upperBound <= units.count {
            let text = String(decoding: units[word.chars], as: UTF16.self)
            if base.count == units.count,
               String(decoding: base[word.chars], as: UTF16.self) == text { continue }
            pin(CursorOption(text: text, span: word.syllables, score: 0), over: picked)
        }
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
        /// "key=text" words a commit of the reached text would learn
        /// (`UserLexicon.learnedWords`); empty when nothing was picked.
        public var learned: [String] = []
    }

    /// Decodes exactly like the IME preview (terminated segments plus the
    /// live-converted pending keys) and reads syllables from the top candidate.
    public static func run(_ decoder: LexiconDecoder, segments: [Composition.Segment],
                           pendingKeys: [String] = [],
                           expected: String, model: Model,
                           fuzzy: Bool = true, toneTolerance: Bool = true,
                           userLexicon: UserLexicon? = nil, maxPicks: Int = 6) -> Outcome {
        let target = Array(expected)
        var pins = UserLexicon()
        var ranks: [Int] = []
        for _ in 0...maxPicks {
            guard let top = decoder.decodeSegments(segments, pendingKeys: pendingKeys, fuzzy: fuzzy,
                                                   toneTolerance: toneTolerance, userLexicon: userLexicon,
                                                   locked: pins.isEmpty ? nil : pins).first else { break }
            let syllables = top.syllables
            let text = Array(top.text)
            if text == target {
                let learned = ranks.isEmpty ? [] : UserLexicon.learnedWords(
                    committed: top, pins: pins, baseline: nil).map { "\($0.key)=\($0.text)" }
                return Outcome(picks: ranks.count, ranks: ranks, learned: learned)
            }
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
