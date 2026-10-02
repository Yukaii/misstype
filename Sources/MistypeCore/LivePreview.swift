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
    /// `settled` holds automatic pins for text already accepted (see
    /// `UserLexicon.settled(from:keep:)`); explicit `locked` pins win over
    /// them. Candidates that break a pin (scoring far below top-1 by the pin
    /// bonus) are dropped: they vary accepted text, which only buried the
    /// alternatives near the cursor.
    public func livePreview(_ composition: Composition, fuzzy: Bool = true, toneTolerance: Bool = true,
                            userLexicon: UserLexicon? = nil, locked: UserLexicon? = nil,
                            settled: UserLexicon? = nil) -> LivePreview {
        let pending = composition.parsed.pending
        let cut = livePendingCut(pending, toneTolerance: toneTolerance)
        // Explicit pins win: settled pins are dropped from any run that has
        // an explicit pin, since spans may overlap without sharing a key
        // (打對 over settled 大 + 對) and both at pinBonus cannot hold.
        let explicitRuns = Set((locked?.entries.keys ?? [:].keys).compactMap { $0.split(separator: "#").first })
        var pins = UserLexicon()
        for (key, texts) in settled?.entries ?? [:]
        where !explicitRuns.contains(key.split(separator: "#").first ?? "") {
            pins.entries[key] = texts
        }
        for (key, texts) in locked?.entries ?? [:] { pins.entries[key] = texts }
        var candidates = decodeSegments(composition.segments, pendingKeys: Array(pending.prefix(cut)),
                                        fuzzy: fuzzy, toneTolerance: toneTolerance,
                                        userLexicon: userLexicon, locked: pins.isEmpty ? nil : pins)
        if !pins.isEmpty, let top = candidates.first {
            candidates = candidates.filter { $0.score > top.score - UserLexicon.pinBonus / 2 }
        }
        return LivePreview(candidates: candidates, rawTail: Array(pending.dropFirst(cut)))
    }
}

extension UserLexicon {
    /// Automatic pins for accepted text: every word of an earlier run
    /// (punctuation or latin closed it) and every word of the run being
    /// typed that ends at least `keep` syllables before its end. Derived
    /// fresh from the displayed top-1 each keystroke — it already honors the
    /// previous settle — so Backspace un-settles naturally. Never learned:
    /// kept apart from explicit pins (user report 2026-09-27: "the front was
    /// already accepted; only compose near the cursor").
    ///
    /// Pins are per CHARACTER ("run#@offset" -> char), not per word: the
    /// accepted text is fixed but word boundaries stay free, so an accepted
    /// 這 can still merge into 這部 when 部 arrives.
    public static func settled(from top: SentenceCandidate, keep: Int) -> UserLexicon {
        var out = UserLexicon()
        guard let lastRun = top.runs.last else { return out }
        let units = Array(top.text.utf16)
        for word in top.alignment where word.chars.upperBound <= units.count {
            let inLastRun = lastRun.contains(word.syllables.lowerBound)
            guard !inLastRun || word.syllables.upperBound <= lastRun.upperBound - keep,
                  let run = top.runs.firstIndex(where: { $0.contains(word.syllables.lowerBound) }),
                  let runStart = top.charOffset(ofSyllable: top.runs[run].lowerBound) else { continue }
            for unit in word.chars {
                out.entries["\(run)#@\(unit - runStart)"] =
                    [String(decoding: units[unit..<unit + 1], as: UTF16.self): Record(count: 1, updatedAt: 0)]
            }
        }
        return out
    }

    /// Run-local settled characters ("@offset" keys after pins(forRun:)).
    func settledUnits() -> [Int: UInt16]? {
        var out: [Int: UInt16] = [:]
        for (key, texts) in entries where key.hasPrefix("@") {
            guard let offset = Int(key.dropFirst()), let unit = texts.keys.first?.utf16.first else { continue }
            out[offset] = unit
        }
        return out.isEmpty ? nil : out
    }
}

extension SessionView {
    /// The open candidate list as one line of text for hosts that draw it
    /// inline after the preedit (`你好 ‹a 妳好  s 尼好›`) instead of in a
    /// window. `selected` is the UTF-16 range of the highlighted row inside
    /// `text`. Nil unless the user opened the list (`listOpen`); the mark
    /// hint is the host's (it is localized). Rows use the same differing-
    /// window trimming as the panel, narrower, since a line holds them all.
    public func inlineList(pageSize: Int = 8) -> (text: String, selected: Range<Int>)? {
        guard listOpen, showsCandidates, mark == nil, !candidates.isEmpty else { return nil }
        let page = min(max(selected, 0) / pageSize, (candidates.count - 1) / pageSize)
        let rows = Array(candidates.dropFirst(page * pageSize).prefix(pageSize))
        let windows = CandidateDisplay.windows(rows, maxChars: 6, context: 1)
        var text = "  ‹"
        var highlight = 0..<0
        for (index, window) in windows.enumerated() {
            if index > 0 { text += "  " }
            let label = keysActive && index < selectionKeys.count ? selectionKeys[index] + " " : ""
            let start = text.utf16.count
            text += label + window
            if page * pageSize + index == selected { highlight = start..<text.utf16.count }
        }
        text += "›"
        let pages = (candidates.count + pageSize - 1) / pageSize
        if pages > 1 { text += " \(page + 1)/\(pages)" }
        return (text, highlight)
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
            var leading = from > 0
            // Too long: keep the end nearest the cursor — the front of the
            // window is older text (user report 2026-09-27).
            if body.count > maxChars {
                body = Array(body.suffix(maxChars))
                leading = true
            }
            return (leading ? "…" : "") + String(body) + (to < row.count ? "…" : "")
        }
    }
}
