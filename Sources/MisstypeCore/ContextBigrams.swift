import Foundation

/// Homophone-disambiguation bigrams (ChiaKey Lexicon shape): a bonus for a
/// word that follows a specific previous word in the same run. Rows only
/// exist where they change a pick, so this re-ranks produced candidates and
/// never creates paths — same contract as learned context rules.
///
/// Source rows are `qstring<TAB>previous<TAB>current<TAB>strength`, where
/// strength is a source-internal order (not a probability). ChiaKey
/// calibrates `unigram(current) + boost + (raw - rawMax)`; the unigram
/// scales differ, so only the delta `boost + raw - rawMax` (0...boost) is
/// kept and scaled by `weight` onto ours. qstring is ignored: matching is
/// by text, so a heterophone word can collect a row meant for its other
/// reading (rare; measured, see project outline).
///
/// Three-column rows `previous<TAB>current<TAB>bonus` are pre-calibrated
/// (tools/chiakey_export.py) and only scaled by `weight`.
public struct ContextBigrams {
    /// current word -> previous word -> bonus
    private var table: [String: [String: Double]] = [:]
    public private(set) var count = 0

    public init(tsv: String, weight: Double = 1.0, boost: Double = 1.5) {
        var rows: [(String, String, Double)] = []
        var calibrated: [(String, String, Double)] = []
        var rawMax = -Double.infinity
        for line in tsv.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty,
               let bonus = Double(fields[2]), bonus.isFinite {
                calibrated.append((String(fields[0]), String(fields[1]), bonus))
                continue
            }
            guard fields.count == 4, !fields[1].isEmpty, !fields[2].isEmpty,
                  let raw = Double(fields[3]), raw.isFinite else { continue }
            rows.append((String(fields[1]), String(fields[2]), raw))
            rawMax = max(rawMax, raw)
        }
        let bonuses = rows.map { ($0.0, $0.1, max(0, boost + $0.2 - rawMax)) } + calibrated
        for (previous, current, delta) in bonuses {
            let bonus = weight * delta
            guard bonus > 0 else { continue }
            if table[current]?[previous].map({ $0 >= bonus }) ?? false { continue }
            table[current, default: [:]][previous] = bonus
        }
        count = table.values.reduce(0) { $0 + $1.count }
    }

    /// Previous-word bonuses for one current word, nil when it has none.
    public func following(_ current: String) -> [String: Double]? {
        table[current]
    }
}
