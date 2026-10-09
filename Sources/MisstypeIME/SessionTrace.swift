import Foundation
import MisstypeMacKit
import MisstypeZigBridge

/// `--session-trace <keys> [--auto-commit N] [--show]`: the real session (Zig
/// core, shipped lexicon) key by key, headless. Prints per-key latency, every
/// auto-commit chunk, the preedit after each key with `--show`, and the final
/// text. `--user-lexicon / --user-dictionary / --channel <path>` replay
/// against COPIES of a user's learned state, so nothing is written back.
/// Editing keys are glyphs, so a debug-log key sequence replays verbatim:
/// ⌫ ⏎ ← → ↑ ↓ ⇥ ⎋ ⌦, and ⇠ ⇢ ⌧ for Option+Left/Right/Backspace.
func runSessionTrace(arguments: [String]) -> Never {
    guard let traceIndex = arguments.firstIndex(of: "--session-trace"), traceIndex + 1 < arguments.count,
          let resources = Bundle.main.resourceURL else { exit(2) }
    MisstypePrefs.register()
    var settings = MisstypePrefs.sessionSettings
    if let flag = arguments.firstIndex(of: "--auto-commit"), flag + 1 < arguments.count,
       let value = Int(arguments[flag + 1]) {
        settings.autoCommitSyllables = value
    }
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("misstype-trace-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    /// A private copy of the file a flag names ("" = memory only).
    func copy(_ flag: String, as name: String) -> String {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return "" }
        let destination = scratch.appendingPathComponent(name)
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[index + 1]), to: destination)
        return destination.path
    }
    guard let engine = ZigEngine(resourceDirectory: resources,
                                 userLexiconPath: copy("--user-lexicon", as: "user_phrases.json")),
          let session = ZigSessionAdapter(engine: engine, settings: { settings }) else {
        FileHandle.standardError.write(Data("misstype: cannot start the Zig engine\n".utf8))
        exit(1)
    }
    engine.setUserDictionaryPath(copy("--user-dictionary", as: "user_dictionary.tsv"))
    engine.setChannelPath(copy("--channel", as: "channel_model.json"))

    let named: [String: KeyEvent.Key] = ["⌫": .backspace, "⏎": .enter, "←": .left, "→": .right,
                                         "↑": .up, "↓": .down, "⇥": .tab, "⎋": .escape, "⌦": .forwardDelete]
    let option: [String: KeyEvent.Key] = ["⇠": .left, "⇢": .right, "⌧": .backspace]
    var committed = ""
    for (count, char) in arguments[traceIndex + 1].enumerated() {
        let label = String(char)
        let event = label == " " ? KeyEvent(.space, text: " ")
            : option[label].map { KeyEvent($0, modifiers: .option) }
            ?? named[label].map { KeyEvent($0) } ?? KeyEvent(.character(label), text: label)
        let started = Date()
        let result = session.handle(event)
        let ms = Date().timeIntervalSince(started) * 1000
        print("time\t\(count + 1)\t\(String(format: "%.1f", ms))")
        if arguments.contains("--show") {
            print("view\t\(count + 1)\t\(preeditWithCursor(session.view.preedit, caretUTF16: session.view.caret))")
        }
        if let text = result.commit {
            committed += text
            print("chunk\t\(count + 1)\t\(text)\tpreedit=\(session.view.preedit)")
        }
    }
    let rest = session.handle(KeyEvent(.enter, text: "\r")).commit ?? ""
    print("final\t\(committed + rest)")
    exit(0)
}
