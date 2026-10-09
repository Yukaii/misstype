import Foundation


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
