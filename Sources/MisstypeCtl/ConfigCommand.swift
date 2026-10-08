import Foundation
import MisstypeCore

/// `misstypectl config …`: reads and writes the same fcitx5 config file the
/// settings page (fcitx5-configtool) edits, `conf/misstype.conf`. Unknown
/// lines and comments are left alone; values are validated first so a typo
/// cannot put the engine into a state the page would refuse.
struct ConfigCommand {
    let env: CtlEnvironment

    enum Kind { case bool, string, int(ClosedRange<Int>), choice([String]) }

    struct Setting {
        let key: String
        let kind: Kind
        let fallback: String
        let summary: String
    }

    /// Mirrors `MisstypeConfig` in linux/fcitx5/src/engine.cpp (keep in step).
    static let settings: [Setting] = [
        .init(key: "RepairStrength", kind: .choice(["Off", "Light", "Standard", "Strong"]), fallback: "Standard",
              summary: "Repair typing mistakes"),
        .init(key: "ToneTolerance", kind: .bool, fallback: "True", summary: "Tolerate wrong tones"),
        .init(key: "UserLearning", kind: .bool, fallback: "True", summary: "Learn phrases you type"),
        .init(key: "ChannelLearning", kind: .bool, fallback: "False",
              summary: "Learn your typing slips (experimental, needs phrase learning)"),
        .init(key: "MixedEnglish", kind: .bool, fallback: "False", summary: "Recognize English words while typing"),
        .init(key: "AutoShowCandidates", kind: .bool, fallback: "False", summary: "Show candidates automatically"),
        .init(key: "ReturnConfirmsSelection", kind: .bool, fallback: "True",
              summary: "Return confirms the selected candidate"),
        .init(key: "CandidateKeys", kind: .string, fallback: SelectionKeys.defaultKeys, summary: "Selection keys"),
        .init(key: "CandidatesPerPage", kind: .int(SelectionKeys.pageSizes), fallback: "8",
              summary: "Candidates per page"),
        .init(key: "CursorCandidates", kind: .choice(["Covering", "EndingAt", "BeginningAt"]), fallback: "Covering",
              summary: "Words listed at the syllable cursor"),
        .init(key: "AutoCommitSyllables", kind: .int(0...64), fallback: "24",
              summary: "Commit long input in chunks after N syllables (0 = never)"),
        .init(key: "ShiftTogglesEnglish", kind: .bool, fallback: "False",
              summary: "Lone Shift switches 中/英 in Misstype (disable fcitx5's Temporarily Toggle Input Method key)"),
    ]

    func run(_ args: [String]) -> Int32 {
        guard let sub = args.first else {
            env.err("misstypectl config: missing subcommand\n\n" + MisstypeCtl.usage)
            return 2
        }
        let parsed = Arguments(Array(args.dropFirst()), valued: ["file"], flagNames: ["no-reload"])
        if let error = parsed.error {
            env.err("misstypectl config: \(error)")
            return 2
        }
        let url = parsed.options["file"].map { URL(fileURLWithPath: $0) } ?? configURL()
        let words = parsed.positional

        switch sub {
        case "path":
            env.out(url.path)
            return 0
        case "list":
            let stored = Self.read(url)
            for setting in Self.settings {
                let value = stored[setting.key] ?? setting.fallback
                env.out("\(setting.key)=\(value)" + (stored[setting.key] == nil ? "  (default)" : ""))
            }
            return 0
        case "get":
            guard words.count == 1, let setting = Self.find(words[0]) else { return unknownKey(words.first) }
            env.out(Self.read(url)[setting.key] ?? setting.fallback)
            return 0
        case "set":
            guard words.count == 2 else {
                env.err("misstypectl config set: expected <Key> <value>")
                return 2
            }
            guard let setting = Self.find(words[0]) else { return unknownKey(words[0]) }
            guard let value = normalize(words[1], for: setting) else { return 1 }
            return write(url, key: setting.key, value: value, reload: !parsed.flags.contains("no-reload"))
        case "reset":
            guard words.count == 1, let setting = Self.find(words[0]) else { return unknownKey(words.first) }
            return write(url, key: setting.key, value: nil, reload: !parsed.flags.contains("no-reload"))
        default:
            env.err("misstypectl config: unknown subcommand “\(sub)”")
            return 2
        }
    }

    // MARK: - Values

    static func find(_ name: String) -> Setting? {
        settings.first { $0.key.lowercased() == name.lowercased() }
    }

    private func unknownKey(_ name: String?) -> Int32 {
        env.err("misstypectl config: unknown key" + (name.map { " “\($0)”" } ?? "")
                + " (known: " + Self.settings.map(\.key).joined(separator: ", ") + ")")
        return 2
    }

    /// The canonical stored spelling of `input`, or nil after reporting why not.
    private func normalize(_ input: String, for setting: Setting) -> String? {
        switch setting.kind {
        case .bool:
            switch input.lowercased() {
            case "true", "on", "yes", "1": return "True"
            case "false", "off", "no", "0": return "False"
            default:
                env.err("misstypectl config: \(setting.key) takes on/off")
                return nil
            }
        case .int(let range):
            guard let value = Int(input), range.contains(value) else {
                env.err("misstypectl config: \(setting.key) takes a number from \(range.lowerBound) to \(range.upperBound)")
                return nil
            }
            return String(value)
        case .choice(let names):
            guard let name = names.first(where: { $0.lowercased() == input.lowercased() }) else {
                env.err("misstypectl config: \(setting.key) takes one of " + names.joined(separator: ", "))
                return nil
            }
            return name
        case .string:
            // Up to the largest page; CandidatesPerPage picks how many are used.
            let keys = SelectionKeys.sanitize(input, pageSize: SelectionKeys.pageSizes.upperBound)
            if keys != input {
                env.err("misstypectl config: selection keys must be distinct keys of the Zhuyin layout "
                        + "(lowercase, no space, at most \(SelectionKeys.pageSizes.upperBound)); "
                        + "the engine would use “\(keys)” instead")
                return nil
            }
            return keys
        }
    }

    // MARK: - File

    private func configURL() -> URL {
        let home = env.variables["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let base = env.variables["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("fcitx5/conf/misstype.conf")
    }

    static func read(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let (key, value) = split(String(line)) else { continue }
            values[key] = value
        }
        return values
    }

    /// `Key=Value` (value optionally quoted); comments and `[Group]` lines are not settings.
    private static func split(_ line: String) -> (String, String)? {
        guard !line.hasPrefix("#"), !line.hasPrefix("["), let equals = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<equals])
        var value = String(line[line.index(after: equals)...])
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return (key, value)
    }

    private static func encode(_ value: String) -> String {
        guard value.contains(where: { "\"\\# \t".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static let reloadArguments = [
        "--session", "--print-reply", "--dest=org.fcitx.Fcitx5", "/controller",
        "org.fcitx.Fcitx.Controller1.ReloadAddonConfig", "string:misstype",
    ]

    /// Sets (or, with nil, removes) one key, keeping every other line as is.
    private func write(_ url: URL, key: String, value: String?, reload: Bool) -> Int32 {
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let index = lines.firstIndex { Self.split($0)?.0 == key }
        switch (index, value) {
        case let (index?, value?): lines[index] = "\(key)=\(Self.encode(value))"
        case let (index?, nil): lines.remove(at: index)
        case let (nil, value?): lines.append("\(key)=\(Self.encode(value))")
        case (nil, nil): break
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            env.err("misstypectl: cannot write \(url.path): \(error.localizedDescription)")
            return 1
        }
        env.out(value.map { "\(key)=\($0)" } ?? "\(key) reset to default")
        // `fcitx5-remote -r` reloads only the global config, not addons, so
        // ask fcitx5 to reload this addon. dbus-send fails (or is missing)
        // when fcitx5 is not running.
        if reload, env.run("dbus-send", Self.reloadArguments, true) != 0 {
            env.err("note: could not ask fcitx5 to reload; the change applies when fcitx5 next starts")
        }
        return 0
    }
}
