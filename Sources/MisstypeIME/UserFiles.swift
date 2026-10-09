import Foundation

/// Where the IME keeps the user's files. The Zig core uses the same paths
/// (storage.dataDirectory); inside the sandbox they live in the container.
enum UserFiles {
    static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Misstype", isDirectory: true)
    }
    /// Learned phrases (portable JSON the user can copy between machines).
    static var learnedPhrases: URL { dataDirectory.appendingPathComponent("user_phrases.json") }
    static var userDictionary: URL { dataDirectory.appendingPathComponent("user_dictionary.tsv") }

    /// Atomic write, creating the directory first.
    static func write(_ text: String, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
