import Foundation

/// Explicit-opt-in user phrase overlay (M4/M5 follow-up).
///
/// Thesis: corpus frequency cannot break residual ties (不大/不打, 嗎/麼,
/// 大隊/打對 — see project-outline M4 findings). The only honest signal is
/// the user's own explicit pick. This layer records exactly that — nothing
/// inferred, nothing imported — and adds a deterministic bonus at decode.
///
/// Keying: toneless-concatenated readings, no separators (e.g. ㄋㄧˇ-ㄏㄠˇ
/// → "ㄋㄧㄏㄠ"). This is deliberate: learn-time segmentation (complete +
/// one pending tail blob) and decode-time segmentation (trie spans) differ,
/// but the concatenated symbol stream is identical for the same keystrokes
/// typed clean. Tone differences collapse on purpose — the stored *text*
/// disambiguates (買/賣 share a key, counts decide). Theoretical collision:
/// two different segmentations of one symbol stream share a key; worst case
/// is a stray bonus on the same text, which is benign.
///
/// Scoring: first explicit record +6.0 (beats word-frequency deltas of a
/// few points AND repair costs up to 6 — an explicit user signal should win
/// both), +1.0 per repeat, capped at +10.0. Bonuses apply only to texts the
/// decoder already produced, so learning can never hallucinate new paths.
///
/// Privacy: local JSON only, default OFF (see MistypePrefs.userLearning),
/// revealed/cleared from the Preferences panel. No network, no inference.
public struct UserLexicon: Codable, Equatable {
    public struct Record: Codable, Equatable {
        public var count: Int
        public var updatedAt: Double // unix epoch, injected for determinism

        public init(count: Int, updatedAt: Double) {
            self.count = count
            self.updatedAt = updatedAt
        }
    }

    /// reading key → text → record.
    public var entries: [String: [String: Record]] = [:]

    public static let fileVersion = 1
    public static let entryCap = 500
    public static let baseBonus = 6.0
    public static let repeatBonus = 1.0
    public static let maxBonus = 10.0
    /// Session-pin bonus: dwarfs any word-score gap, so a pinned segment
    /// always wins its span. Session-only (never persisted) — see `locked`.
    public static let pinBonus = 1000.0

    public init() {}
    public init(entries: [String: [String: Record]]) { self.entries = entries }

    public var count: Int { entries.values.reduce(0) { $0 + $1.count } }
    public var isEmpty: Bool { entries.isEmpty }

    /// Toneless-concatenated key for a syllable run.
    public static func key(for syllables: [Syllable]) -> String {
        key(forReadings: syllables.map(\.reading))
    }

    /// Same key from raw reading strings (decode-time trie spans).
    public static func key(forReadings readings: [String]) -> String {
        readings.map { $0.filter { !"ˊˇˋ˙".contains($0) } }.joined()
    }

    public mutating func record(key: String, text: String, at: Date = Date()) {
        guard !key.isEmpty, !text.isEmpty, text.count <= 32 else { return }
        var texts = entries[key, default: [:]]
        let stamp = at.timeIntervalSince1970
        if var existing = texts[text] {
            existing.count += 1
            existing.updatedAt = stamp
            texts[text] = existing
        } else {
            texts[text] = Record(count: 1, updatedAt: stamp)
        }
        entries[key] = texts
        evictIfNeeded()
    }

    public func bonus(key: String, text: String) -> Double {
        guard let record = entries[key]?[text] else { return 0 }
        return min(Self.baseBonus + Double(record.count - 1) * Self.repeatBonus,
                   Self.maxBonus)
    }

    // MARK: - Persistence (Codable file wrapper with version)

    private struct FileWrapper: Codable {
        var version: Int
        var entries: [String: [String: Record]]
    }

    public func encoded() throws -> Data {
        // Sorted keys for stable diffs.
        let sorted = entries.mapValues { texts in
            Dictionary(uniqueKeysWithValues: texts.sorted { $0.key < $1.key })
        }
        return try JSONEncoder().encode(FileWrapper(version: Self.fileVersion, entries: sorted))
    }

    public static func decoded(from data: Data) throws -> UserLexicon {
        let wrapper = try JSONDecoder().decode(FileWrapper.self, from: data)
        guard wrapper.version == fileVersion else { return UserLexicon() }
        return UserLexicon(entries: wrapper.entries)
    }

    /// Default location: ~/Library/Application Support/Mistype/user_phrases.json.
    /// Documented export path — the file is portable JSON the user can copy.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mistype/user_phrases.json")
    }

    public static func load(from url: URL = defaultURL) -> UserLexicon {
        guard let data = try? Data(contentsOf: url),
              let lexicon = try? decoded(from: data) else { return UserLexicon() }
        return lexicon
    }

    public func save(to url: URL = defaultURL) {
        guard let data = try? encoded() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private mutating func evictIfNeeded() {
        var total = count
        while total > Self.entryCap {
            // Evict lowest (count, oldest) first — deterministic.
            var victim: (key: String, text: String)?
            var victimScore = (Int.max, Double.greatestFiniteMagnitude)
            for (key, texts) in entries {
                for (text, record) in texts {
                    let score = (record.count, record.updatedAt)
                    if score < victimScore {
                        victimScore = (score.0, score.1)
                        victim = (key, text)
                    }
                }
            }
            guard let victim else { break }
            entries[victim.key]?.removeValue(forKey: victim.text)
            if entries[victim.key]?.isEmpty == true { entries.removeValue(forKey: victim.key) }
            total -= 1
        }
    }
}
