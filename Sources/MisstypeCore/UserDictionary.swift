import Foundation

/// The user's own dictionary (vChewing parity): words the user adds on
/// purpose and built-in words the user excludes. Distinct from `UserLexicon`,
/// which only re-ranks candidates the decoder already produced — a
/// `UserDictionary` word is a real trie entry, so it can introduce a path the
/// built-in lexicon never had (a name, jargon, a rare character).
///
/// File format (`user_dictionary.tsv`, plain UTF-8, hand-editable; the
/// Settings editor edits exactly this text). Lines are vChewing's userdata
/// format, so its files (and `vChewing-userdata-generator` output) load as is:
///
/// ```text
/// # text reading [weight]                weight ≤ 0, default 0 (strongest)
/// 黃昱愷 ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ
/// !打對 ㄉㄚˇ-ㄉㄨㄟˋ                      "!" hides a built-in word (ours)
/// ```
///
/// Fields are separated by any run of spaces or tabs (text and reading never
/// contain whitespace). The earlier `reading<TAB>text` order is still read —
/// the Zhuyin field gives the order away — and rewritten on the next save.
///
/// Readings are hyphen-separated syllables WITH tones, exactly the trie path
/// of `lexicon.tsv` (first tone has no mark: `ㄇㄚ`). Scores share the
/// lexicon's log-probability scale (built-in words run about -16…-3.6), so
/// the default 0 outranks any built-in word without being a session pin.
public struct UserDictionary: Equatable, Sendable {
    public struct Entry: Equatable, Hashable, Sendable {
        public var reading: String
        public var text: String
        /// Lexicon-scale score; ignored for exclusions.
        public var weight: Double
        public init(reading: String, text: String, weight: Double = UserDictionary.defaultWeight) {
            self.reading = reading
            self.text = text
            self.weight = weight
        }
    }

    public struct Problem: Equatable, Sendable {
        /// 1-based line number in the source text.
        public let line: Int
        public let message: String
    }

    public static let defaultWeight = 0.0
    public static let maxSyllables = 8
    public static let minSyllables = 2
    /// Same cap as `UserLexicon.record`: a phrase, not a paragraph.
    public static let maxTextLength = 32

    public private(set) var added: [Entry] = []
    public private(set) var excluded: [Entry] = []

    public init() {}

    public var isEmpty: Bool { added.isEmpty && excluded.isEmpty }
    public var count: Int { added.count + excluded.count }

    public func contains(reading: String, text: String) -> Bool {
        added.contains { $0.reading == reading && $0.text == text }
    }

    public func isExcluded(reading: String, text: String) -> Bool {
        excluded.contains { $0.reading == reading && $0.text == text }
    }

    /// Adds (or re-weights) a word. Adding a word that is excluded lifts the
    /// exclusion — the last gesture wins.
    @discardableResult
    public mutating func add(reading: String, text: String, weight: Double = defaultWeight) -> Bool {
        guard Self.validate(reading: reading, text: text) == nil else { return false }
        excluded.removeAll { $0.reading == reading && $0.text == text }
        if let index = added.firstIndex(where: { $0.reading == reading && $0.text == text }) {
            added[index].weight = weight
        } else {
            added.append(Entry(reading: reading, text: text, weight: weight))
        }
        return true
    }

    @discardableResult
    public mutating func remove(reading: String, text: String) -> Bool {
        let before = added.count
        added.removeAll { $0.reading == reading && $0.text == text }
        return added.count != before
    }

    /// Hides a built-in word. A user-added word of the same pair is dropped
    /// (excluding it means it should no longer appear at all).
    @discardableResult
    public mutating func exclude(reading: String, text: String) -> Bool {
        guard Self.validate(reading: reading, text: text) == nil else { return false }
        added.removeAll { $0.reading == reading && $0.text == text }
        if !isExcluded(reading: reading, text: text) {
            excluded.append(Entry(reading: reading, text: text, weight: 0))
        }
        return true
    }

    @discardableResult
    public mutating func unexclude(reading: String, text: String) -> Bool {
        let before = excluded.count
        excluded.removeAll { $0.reading == reading && $0.text == text }
        return excluded.count != before
    }

    // MARK: - Text format

    private static let toneMarks: Set<Character> = ["ˊ", "ˇ", "ˋ", "˙"]
    private static let symbols: Set<Character> = Set(ZhuyinKeyboard.symbols.values.joined())

    /// Why a (reading, text) pair cannot be stored, or nil when it can.
    /// Each syllable must be Zhuyin symbols with at most one trailing tone
    /// mark, and the text needs one character per syllable (the decoder
    /// aligns characters to syllables one to one).
    public static func validate(reading: String, text: String) -> String? {
        let syllables = reading.split(separator: "-", omittingEmptySubsequences: false)
        guard !reading.isEmpty, syllables.allSatisfy({ !$0.isEmpty }) else { return "empty syllable in reading" }
        guard syllables.count <= maxSyllables else { return "more than \(maxSyllables) syllables" }
        for syllable in syllables {
            let body = syllable.last.map { toneMarks.contains($0) } == true ? syllable.dropLast() : syllable[...]
            guard !body.isEmpty, body.allSatisfy({ symbols.contains($0) }) else {
                return "“\(syllable)” is not a Zhuyin syllable"
            }
        }
        guard !text.isEmpty, text.count <= maxTextLength,
              !text.contains(where: { $0.isWhitespace || $0 == "\t" }) else { return "text must be one word, no spaces" }
        guard text.count == syllables.count else {
            return "\(text.count) character\(text.count == 1 ? "" : "s") for \(syllables.count) syllable\(syllables.count == 1 ? "" : "s")"
        }
        return nil
    }

    private static func isReadingLike(_ field: String) -> Bool {
        field.allSatisfy { $0 == "-" || toneMarks.contains($0) || symbols.contains($0) }
    }

    /// Parses the file text. Bad lines are reported and skipped, never fatal:
    /// a typo must not take the whole dictionary down with it.
    public static func parse(_ source: String) -> (dictionary: UserDictionary, problems: [Problem]) {
        var dictionary = UserDictionary()
        var problems: [Problem] = []
        for (offset, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.hasPrefix("#") else { continue }
            let isExclusion = line.hasPrefix("!")
            var fields = (isExclusion ? String(line.dropFirst()) : line)
                .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2, fields.count <= 3 else {
                problems.append(Problem(line: offset + 1, message: "expected text reading [weight]"))
                continue
            }
            // Legacy order: reading first. Only a Zhuyin-looking first field
            // flips it, so a bad vChewing line still reports against text/reading.
            if isReadingLike(fields[0]), !isReadingLike(fields[1]) { fields.swapAt(0, 1) }
            let (text, reading) = (fields[0], fields[1])
            if let message = validate(reading: reading, text: text) {
                problems.append(Problem(line: offset + 1, message: message))
                continue
            }
            var weight = defaultWeight
            if fields.count == 3 {
                guard !isExclusion, let value = Double(fields[2]), value.isFinite, value <= 0 else {
                    problems.append(Problem(line: offset + 1, message: "weight must be a number ≤ 0 (exclusions take none)"))
                    continue
                }
                weight = value
            }
            if isExclusion {
                dictionary.exclude(reading: reading, text: text)
            } else {
                dictionary.add(reading: reading, text: text, weight: weight)
            }
        }
        return (dictionary, problems)
    }

    public struct ImportResult: Equatable, Sendable {
        public var text: String
        public var added = 0
        /// Valid lines already present (same reading and text).
        public var duplicates = 0
        public var problems: [Problem] = []
    }

    /// Appends the new entries of `source` (vChewing userdata or our own file)
    /// to the editor `text`, in canonical lines, leaving existing text, comments
    /// and order untouched. Nothing is written to disk.
    public static func importing(_ source: String, into text: String) -> ImportResult {
        let existing = parse(text).dictionary
        let incoming = parse(source)
        var result = ImportResult(text: text, problems: incoming.problems)
        var lines: [String] = []
        for entry in incoming.dictionary.added {
            if existing.contains(reading: entry.reading, text: entry.text) { result.duplicates += 1; continue }
            lines.append(entry.weight == defaultWeight
                ? "\(entry.text) \(entry.reading)" : "\(entry.text) \(entry.reading) \(entry.weight)")
        }
        for entry in incoming.dictionary.excluded {
            if existing.isExcluded(reading: entry.reading, text: entry.text) { result.duplicates += 1; continue }
            lines.append("!\(entry.text) \(entry.reading)")
        }
        result.added = lines.count
        if !lines.isEmpty {
            if !result.text.isEmpty, !result.text.hasSuffix("\n") { result.text += "\n" }
            result.text += lines.joined(separator: "\n") + "\n"
        }
        return result
    }

    /// Canonical file text: header comment, additions, then exclusions, each
    /// in insertion order so hand-edits stay where the user put them.
    public func serialized() -> String {
        var lines = ["# Misstype user dictionary (vChewing format): text reading [weight]; \"!\" hides a built-in word."]
        for entry in added {
            lines.append(entry.weight == Self.defaultWeight
                ? "\(entry.text) \(entry.reading)"
                : "\(entry.text) \(entry.reading) \(entry.weight)")
        }
        for entry in excluded { lines.append("!\(entry.text) \(entry.reading)") }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Persistence

    /// `user_dictionary.tsv` next to the learned-phrase store.
    public static var defaultURL: URL {
        UserLexicon.defaultURL.deletingLastPathComponent().appendingPathComponent("user_dictionary.tsv")
    }

    /// Missing or unreadable file = empty dictionary (the offline baseline).
    public static func load(from url: URL = defaultURL) -> UserDictionary {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return UserDictionary() }
        return parse(text).dictionary
    }

    @discardableResult
    public func save(to url: URL = defaultURL) -> Bool {
        Self.write(text: serialized(), to: url)
    }

    /// Writes raw text (the Settings editor saves what the user typed, so
    /// comments and ordering survive).
    @discardableResult
    public static func write(text: String, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
    }
}
