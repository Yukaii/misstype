import Foundation
import CMisstype

/// Minimal Swift-facing handle for the Zig C ABI.
///
/// The IMK adapter still owns the richer Swift presentation model. This type
/// intentionally keeps the first cutover seam small and testable: it proves
/// that SwiftPM links the universal Zig library and that an engine/session can
/// be created and released with C ownership rules.
public final class ZigEngineProbe {
    public init() {}

    public var abiVersion: Int32 { misstype_abi_version() }

    /// Runs one synthetic composition and returns the preedit. The resource
    /// directory must contain lexicon.tsv and is supplied by the caller so
    /// tests never read a user's files.
    public func preedit(resourceDirectory: String) -> String? {
        let engine = resourceDirectory.withCString { path in
            "".withCString { misstype_engine_new(path, $0) }
        }
        guard let engine else { return nil }
        defer { misstype_engine_free(engine) }
        guard let session = misstype_session_new(engine) else { return nil }
        defer { misstype_session_free(session) }

        for byte in Array("su3".utf8) {
            var label = [CChar(bitPattern: byte), 0]
            label.withUnsafeMutableBufferPointer { buffer in
                var event = misstype_key_event(kind: MISSTYPE_KEY_CHARACTER,
                                              label: UnsafePointer(buffer.baseAddress!), text: UnsafePointer(buffer.baseAddress!),
                                              modifiers: 0, is_release: 0, native_code: -1, timestamp: -1)
                let result = misstype_session_handle(session, &event)
                misstype_string_free(result.commit)
            }
        }
        guard let view = misstype_session_view(session) else { return nil }
        defer { misstype_view_free(view) }
        guard let preedit = view.pointee.preedit else { return nil }
        return String(cString: preedit)
    }
}

/// Owning Swift handle used by the macOS adapter.
public final class ZigEngine {
    let handle: OpaquePointer

    /// `userLexiconPath`: nil = the platform default, "" = memory only.
    public init?(resourceDirectory: URL, userLexiconPath: String?) {
        let created: OpaquePointer? = resourceDirectory.path.withCString { resources in
            if let path = userLexiconPath {
                return path.withCString { misstype_engine_new(resources, $0) }
            }
            return misstype_engine_new(resources, nil)
        }
        guard let created else { return nil }
        handle = created
    }

    deinit { misstype_engine_free(handle) }

    public var isEnglish: Bool { misstype_engine_is_english(handle) != 0 }

    public func setSettings(_ settings: misstype_settings) {
        var value = settings
        misstype_engine_set_settings(handle, &value)
    }

    public func setKeyBindings(_ text: String) {
        text.withCString { misstype_engine_set_key_bindings(handle, $0) }
    }

    public func makeSession() -> OpaquePointer? { misstype_session_new(handle) }

    // MARK: User data files
    //
    // `nil` selects the platform default path (~/Library/Application
    // Support/Misstype/ on macOS, inside the sandbox container for the IME);
    // "" keeps the data in memory only.

    /// Points the engine at `user_dictionary.tsv` and loads it.
    public func setUserDictionaryPath(_ path: String?) {
        if let path { path.withCString { misstype_engine_set_user_dictionary_path(handle, $0) } }
        else { misstype_engine_set_user_dictionary_path(handle, nil) }
    }

    /// Re-reads the default `user_dictionary.tsv` after an outside edit.
    public func reloadUserDictionary() { setUserDictionaryPath(nil) }

    /// Points the engine at `channel_model.json` and loads it.
    public func setChannelPath(_ path: String?) {
        if let path { path.withCString { misstype_engine_set_channel_path(handle, $0) } }
        else { misstype_engine_set_channel_path(handle, nil) }
    }

    public func setChannelLearning(_ enabled: Bool) { misstype_engine_set_channel_learning(handle, enabled ? 1 : 0) }

    /// 0 off, 1 light, 2 standard, 3 strong.
    public func setRepairStrength(_ level: Int32) { misstype_engine_set_repair_strength(handle, level) }

    public var learnedPhraseCount: Int { Int(misstype_engine_learned_phrase_count(handle)) }
    public func reloadLearnedPhrases() { misstype_engine_reload_learned_phrases(handle) }
    public func saveLearnedPhrases() { misstype_engine_save_learned_phrases(handle) }
    public func clearLearnedPhrases() { misstype_engine_clear_learned_phrases(handle) }
    public func clearChannel() { misstype_engine_clear_channel(handle) }

    public struct ChannelPair: Equatable, Sendable {
        public let typed: String
        public let intended: String
        public let cost: Double
    }

    /// Learned typing slips the decoder uses, cheapest first.
    public var channelPairs: [ChannelPair] {
        Self.take(misstype_engine_channel_pairs(handle)).split(separator: "\n").compactMap { row in
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let cost = Double(fields[2]) else { return nil }
            return ChannelPair(typed: String(fields[0]), intended: String(fields[1]), cost: cost)
        }
    }

    /// Canonical text of the user dictionary the engine has loaded.
    public var userDictionaryText: String { Self.take(misstype_engine_user_dictionary_text(handle)) }

    // MARK: Stateless helpers

    public struct DictionaryCheck: Equatable, Sendable {
        public struct Problem: Equatable, Sendable {
            public let line: Int
            public let message: String
        }
        public let problems: [Problem]
        public let added: Int
        public let hidden: Int
    }

    /// Problems and word counts of user dictionary editor text.
    public static func checkUserDictionary(_ text: String) -> DictionaryCheck {
        var added: Int32 = 0, hidden: Int32 = 0
        let rows = text.withCString { take(misstype_user_dictionary_check($0, &added, &hidden)) }
        let problems = rows.split(separator: "\n").compactMap { row -> DictionaryCheck.Problem? in
            let fields = row.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let line = Int(fields[0]) else { return nil }
            return DictionaryCheck.Problem(line: line, message: String(fields[1]))
        }
        return DictionaryCheck(problems: problems, added: Int(added), hidden: Int(hidden))
    }

    public struct DictionaryImport: Equatable, Sendable {
        public let text: String
        public let added: Int
        public let duplicates: Int
        public let skipped: Int
    }

    /// Appends the new entries of `source` to editor `text` (nothing is written).
    public static func importUserDictionary(_ source: String, into text: String) -> DictionaryImport {
        var added: Int32 = 0, duplicates: Int32 = 0, skipped: Int32 = 0
        let merged = text.withCString { textPointer in
            source.withCString { take(misstype_user_dictionary_import(textPointer, $0, &added, &duplicates, &skipped)) }
        }
        return DictionaryImport(text: merged, added: Int(added), duplicates: Int(duplicates), skipped: Int(skipped))
    }

    /// What a macOS virtual key code is: the key kind and, for character
    /// keys, its US-ANSI label.
    public static func macKey(_ code: Int) -> (kind: misstype_key_kind, label: String?) {
        var label: UnsafePointer<CChar>?
        let kind = misstype_key_from_mac(Int32(code), &label)
        return (kind, label.map { String(cString: $0) })
    }

    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { misstype_string_free(pointer) }
        return String(cString: pointer)
    }
}
