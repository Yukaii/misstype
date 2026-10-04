import Foundation

/// User phrase overlay (M4/M5 follow-up): explicit picks only, local only.
/// Default ON (see MisstypePrefs.userLearning), opt-out anytime; the store
/// stays a portable local JSON the user can reveal or clear.
///
/// Thesis: corpus frequency cannot break residual ties (不大/不打, 嗎/麼,
/// 大隊/打對 — see project-outline M4 findings). The only honest signal is
/// the user's own explicit pick. This layer records exactly that — nothing
/// inferred, nothing imported — and adds a deterministic bonus at decode.
///
/// Keying: toneless-concatenated readings, no separators (e.g. ㄋㄧˇ-ㄏㄠˇ
/// → "ㄋㄧㄏㄠ"). This is deliberate: a learned word's readings (from the
/// committed candidate's syllables) and a later decode's trie spans may
/// carry different tones or splits, but the concatenated symbol stream is
/// identical for the same keystrokes typed clean. Tone differences collapse on purpose — the stored *text*
/// disambiguates (買/賣 share a key, counts decide). Theoretical collision:
/// two different segmentations of one symbol stream share a key; worst case
/// is a stray bonus on the same text, which is benign.
///
/// Scoring: first explicit record +6.0 (beats word-frequency deltas of a
/// few points AND repair costs up to 6 — an explicit user signal should win
/// both), +1.0 per repeat, capped at +10.0. Bonuses apply only to texts the
/// decoder already produced, so learning can never hallucinate new paths.
///
/// Privacy: local JSON only, default ON with opt-out (MisstypePrefs.userLearning),
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

    /// v2 (2026-09-27): word-level + context-keyed learning. v1 files held
    /// mostly whole-sentence entries that never applied; they load as empty
    /// and are overwritten on the next save (user-approved reset).
    public static let fileVersion = 2
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
        return Self.bonus(for: record)
    }

    private static func bonus(for record: Record) -> Double {
        min(baseBonus + Double(record.count - 1) * repeatBonus, maxBonus)
    }

    /// Context-keyed entry: "previous word|readings". A single character
    /// picked inside a sentence is learned only after the word it followed
    /// (下次|ㄗㄞ -> 再), so it never becomes a global bias (再 over 在).
    public static func contextKey(previous: String, readings: String) -> String {
        "\(previous)|\(readings)"
    }

    public struct ContextRule: Equatable {
        public let previous: String
        public let text: String
        public let bonus: Double
    }

    /// Context entries indexed by readings for the decode loop; nil when
    /// there are none, so plain decodes pay nothing.
    public func contextRules() -> [String: [ContextRule]]? {
        var rules: [String: [ContextRule]] = [:]
        for (key, texts) in entries {
            guard let bar = key.firstIndex(of: "|") else { continue }
            let previous = String(key[..<bar]), readings = String(key[key.index(after: bar)...])
            for (text, record) in texts {
                rules[readings, default: []].append(
                    ContextRule(previous: previous, text: text, bonus: Self.bonus(for: record)))
            }
        }
        return rules.isEmpty ? nil : rules
    }

    /// Matching learned phrases for an explicit Jev run. Mirrors the Python
    /// harness (`tools/lm_choose.load_user_preferences`): exact reading-key
    /// match only, timestamps stripped, unrelated readings excluded — the
    /// caller deliberately sends only these rows to the remote evaluator.
    /// Rows are `{"text", "count"}` (count stringified: the native state
    /// contract is `[[String: String]]`), best count first, capped.
    public func matchingPreferences(forBases bases: [String],
                                    maxCount: Int = JevTrigger.maxPreferences) -> [[String: String]] {
        let key = bases.joined()
        guard !key.isEmpty, let texts = entries[key], maxCount > 0 else { return [] }
        return texts
            .sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
            .prefix(maxCount)
            .map { ["text": $0.key, "count": "\($0.value.count)"] }
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

    /// Default location: ~/Library/Application Support/Misstype/user_phrases.json
    /// on macOS, $XDG_DATA_HOME/misstype/user_phrases.json (default
    /// ~/.local/share) elsewhere. Documented export path — the file is
    /// portable JSON the user can copy between platforms.
    public static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/Misstype/user_phrases.json")
        #else
        let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        let data = xdg.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/share", isDirectory: true)
        return data.appendingPathComponent("misstype/user_phrases.json")
        #endif
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
