import Foundation
import MisstypeCore

/// `misstypectl dict …`: edits `user_dictionary.tsv` as text, line by line, so
/// comments and ordering the user wrote by hand survive (the same promise the
/// macOS Settings editor makes). Validation is `UserDictionary`'s own.
struct DictCommand {
    let env: CtlEnvironment

    func run(_ args: [String]) -> Int32 {
        guard let sub = args.first else {
            env.err("misstypectl dict: missing subcommand\n\n" + MisstypeCtl.usage)
            return 2
        }
        let parsed = Arguments(Array(args.dropFirst()), valued: ["file", "weight"], flagNames: ["tsv"])
        if let error = parsed.error {
            env.err("misstypectl dict: \(error)")
            return 2
        }
        let url = parsed.options["file"].map { URL(fileURLWithPath: $0) } ?? UserDictionary.defaultURL
        let words = parsed.positional

        switch sub {
        case "path":
            env.out(url.path)
            return 0
        case "list":
            return list(url, tsv: parsed.flags.contains("tsv"))
        case "check":
            return check(url)
        case "edit":
            return edit(url)
        case "gui":
            guard let status = env.run("misstype-dictionary-editor", parsed.options["file"].map { ["--file", $0] } ?? [], false) else {
                env.err("misstypectl: misstype-dictionary-editor is not installed (try `misstypectl dict edit`)")
                return 1
            }
            return status
        case "add", "remove", "exclude", "unexclude":
            guard words.count == 2 else {
                env.err("misstypectl dict \(sub): expected <reading> <text>")
                return 2
            }
            return change(sub, reading: words[0], text: words[1], weight: parsed.options["weight"], url: url)
        default:
            env.err("misstypectl dict: unknown subcommand “\(sub)”")
            return 2
        }
    }

    // MARK: - Reading

    private func source(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func list(_ url: URL, tsv: Bool) -> Int32 {
        let dictionary = UserDictionary.parse(source(url)).dictionary
        for entry in dictionary.added {
            env.out(tsv ? DictLine.format(entry: entry, excluded: false)
                        : "\(entry.reading)  \(entry.text)" + (entry.weight == UserDictionary.defaultWeight ? "" : "  (weight \(entry.weight))"))
        }
        for entry in dictionary.excluded {
            env.out(tsv ? DictLine.format(entry: entry, excluded: true) : "\(entry.reading)  \(entry.text)  (hidden built-in)")
        }
        return 0
    }

    private func check(_ url: URL) -> Int32 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            env.out("\(url.path): no file yet (nothing to check)")
            return 0
        }
        let problems = UserDictionary.parse(source(url)).problems
        for problem in problems { env.err("\(url.path):\(problem.line): \(problem.message)") }
        if problems.isEmpty { env.out("\(url.path): ok") }
        return problems.isEmpty ? 0 : 1
    }

    private func edit(_ url: URL) -> Int32 {
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = UserDictionary.write(text: UserDictionary().serialized(), to: url)
        }
        let editor = [env.variables["VISUAL"], env.variables["EDITOR"]]
            .compactMap { $0 }.first { !$0.isEmpty } ?? "vi"
        guard let status = env.run(editor, [url.path], false) else {
            env.err("misstypectl: cannot start editor “\(editor)” (set $EDITOR)")
            return 1
        }
        guard status == 0 else { return status }
        return check(url)
    }

    // MARK: - Changing

    private func change(_ sub: String, reading: String, text: String, weight: String?, url: URL) -> Int32 {
        var value = UserDictionary.defaultWeight
        if let weight {
            guard sub == "add" else {
                env.err("misstypectl dict \(sub): --weight only applies to add")
                return 2
            }
            guard let parsed = Double(weight), parsed.isFinite, parsed <= 0 else {
                env.err("misstypectl dict add: weight must be a number ≤ 0")
                return 2
            }
            value = parsed
        }
        if sub == "add" || sub == "exclude", let problem = UserDictionary.validate(reading: reading, text: text) {
            env.err("misstypectl dict \(sub): \(problem)")
            return 1
        }

        var lines = source(url).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let match: (String) -> DictLine? = { line in
            DictLine(line).flatMap { $0.reading == reading && $0.text == text ? $0 : nil }
        }
        let existing = lines.compactMap(match)

        switch sub {
        case "add":
            if let current = existing.first(where: { !$0.excluded }), current.weight == value {
                env.out("already there: \(reading)  \(text)")
                return 0
            }
            lines.removeAll { match($0) != nil } // re-weighting or lifting a hide: the last gesture wins
            lines.append(DictLine.format(entry: .init(reading: reading, text: text, weight: value), excluded: false))
        case "remove":
            guard existing.contains(where: { !$0.excluded }) else {
                env.err("not in your dictionary: \(reading)  \(text)")
                return 1
            }
            lines.removeAll { match($0).map { !$0.excluded } == true }
        case "exclude":
            if existing.contains(where: { $0.excluded }), !existing.contains(where: { !$0.excluded }) {
                env.out("already hidden: \(reading)  \(text)")
                return 0
            }
            lines.removeAll { match($0) != nil }
            lines.append(DictLine.format(entry: .init(reading: reading, text: text, weight: 0), excluded: true))
        default: // unexclude
            guard existing.contains(where: { $0.excluded }) else {
                env.err("not hidden: \(reading)  \(text)")
                return 1
            }
            lines.removeAll { match($0).map { $0.excluded } == true }
        }

        var output = lines.joined(separator: "\n") + "\n"
        if lines.isEmpty { output = UserDictionary().serialized() }
        guard UserDictionary.write(text: output, to: url) else {
            env.err("misstypectl: cannot write \(url.path)")
            return 1
        }
        env.out("\(sub): \(reading)  \(text)")
        return 0
    }
}

/// One data line of `user_dictionary.tsv`, split the way `UserDictionary.parse`
/// splits it (comments, blanks and bad lines are not data lines).
struct DictLine {
    var excluded: Bool
    var reading: String
    var text: String
    var weight: Double

    init?(_ raw: String) {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.hasPrefix("#") else { return nil }
        excluded = line.hasPrefix("!")
        let fields = (excluded ? String(line.dropFirst()) : line).split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 2, fields.count <= 3,
              UserDictionary.validate(reading: fields[0], text: fields[1]) == nil else { return nil }
        reading = fields[0]
        text = fields[1]
        weight = fields.count == 3 ? (Double(fields[2]) ?? UserDictionary.defaultWeight) : UserDictionary.defaultWeight
    }

    static func format(entry: UserDictionary.Entry, excluded: Bool) -> String {
        if excluded { return "!\(entry.reading)\t\(entry.text)" }
        return entry.weight == UserDictionary.defaultWeight
            ? "\(entry.reading)\t\(entry.text)"
            : "\(entry.reading)\t\(entry.text)\t\(entry.weight)"
    }
}
