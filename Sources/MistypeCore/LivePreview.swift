import Foundation

/// What the IME shows while composing: candidates for everything converted
/// so far plus the raw Bopomofo tail (`livePendingCut`). One implementation
/// for the IME preview, commit, the CLI, and replay tools.
public struct LivePreview {
    public let candidates: [SentenceCandidate]
    /// Pending keys shown raw (the syllable still being typed, or 注音文).
    public let rawTail: [String]

    public var rawText: String { rawTail.compactMap { ZhuyinKeyboard.symbols[$0] }.joined() }

    /// Preview string for the candidate at `selected` (converted + raw tail).
    public func text(selected: Int = 0) -> String {
        (candidates.indices.contains(selected) ? candidates[selected].text : "") + rawText
    }
}

extension LexiconDecoder {
    public func livePreview(_ composition: Composition, fuzzy: Bool = true, toneTolerance: Bool = true,
                            userLexicon: UserLexicon? = nil, locked: UserLexicon? = nil) -> LivePreview {
        let pending = composition.parsed.pending
        let cut = livePendingCut(pending, toneTolerance: toneTolerance)
        let candidates = decodeSegments(composition.segments, pendingKeys: Array(pending.prefix(cut)),
                                        fuzzy: fuzzy, toneTolerance: toneTolerance,
                                        userLexicon: userLexicon, locked: locked)
        return LivePreview(candidates: candidates, rawTail: Array(pending.dropFirst(cut)))
    }
}

/// Panel row text for sentence candidates. Live conversion makes every row
/// a long, near-identical sentence; front-truncating each row left eight
/// identical-looking rows whose differences were cut off. Instead every row
/// shows the same window: the span where the rows differ from the first,
/// plus `context` characters on each side, with "…" where text is cut.
public enum CandidateDisplay {
    public static func windows(_ texts: [String], maxChars: Int = 14, context: Int = 2) -> [String] {
        let rows = texts.map(Array.init)
        guard let reference = rows.first else { return [] }
        if rows.count == 1 {
            return [reference.count > maxChars ? "…" + String(reference.suffix(maxChars)) : texts[0]]
        }
        var start = reference.count, tail = reference.count
        for row in rows.dropFirst() {
            let limit = min(row.count, reference.count)
            var prefix = 0
            while prefix < limit, row[prefix] == reference[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < limit - prefix,
                  row[row.count - 1 - suffix] == reference[reference.count - 1 - suffix] { suffix += 1 }
            start = min(start, prefix)
            tail = min(tail, suffix)
        }
        start = max(0, start - context)
        tail = max(0, tail - context)
        return rows.map { row in
            let from = min(start, row.count), to = max(from, row.count - tail)
            var body = Array(row[from..<to])
            var trailing = to < row.count
            if body.count > maxChars {
                body = Array(body.prefix(maxChars))
                trailing = true
            }
            return (from > 0 ? "…" : "") + String(body) + (trailing ? "…" : "")
        }
    }
}
