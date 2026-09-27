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
