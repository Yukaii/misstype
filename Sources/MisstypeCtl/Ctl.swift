import Foundation
import MisstypeCore

/// Everything the command line touches outside its own arguments, so tests
/// can run commands against a temp directory without spawning processes.
public struct CtlEnvironment {
    public var variables: [String: String]
    public var out: (String) -> Void
    public var err: (String) -> Void
    /// Runs a program attached to the terminal (`quiet`: its output is dropped);
    /// nil = could not start it.
    public var run: (_ program: String, _ arguments: [String], _ quiet: Bool) -> Int32?

    public init(variables: [String: String], out: @escaping (String) -> Void,
                err: @escaping (String) -> Void,
                run: @escaping (String, [String], Bool) -> Int32?) {
        self.variables = variables
        self.out = out
        self.err = err
        self.run = run
    }

    public static var live: CtlEnvironment {
        CtlEnvironment(
            variables: ProcessInfo.processInfo.environment,
            out: { print($0) },
            err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
            run: { program, arguments, quiet in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [program] + arguments
                if quiet {
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                }
                do { try process.run() } catch { return nil }
                process.waitUntilExit()
                // env exits 127 when the program does not exist.
                return process.terminationStatus == 127 ? nil : process.terminationStatus
            })
    }
}

/// `misstypectl`: the command-line side of Misstype's settings and dictionary
/// on Linux (the Settings window's counterpart). Plain-text in, plain-text
/// out: nothing here ever contacts a network.
public enum MisstypeCtl {
    static let usage = """
    usage: misstypectl <command>

      dict list [--tsv]                       show my words (and hidden built-ins)
      dict add <reading> <text> [--weight W]  add a word, e.g. ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ 黃昱愷
      dict remove <reading> <text>            delete a word you added
      dict exclude <reading> <text>           hide a built-in word
      dict unexclude <reading> <text>         show it again
      dict check                              report lines the engine would skip
      dict edit                               open the file in $VISUAL/$EDITOR, then check
      dict gui                                open the graphical editor
      dict path                               print the file location

      config list                             all settings with current values
      config get <Key>
      config set <Key> <value>                applies at once (fcitx5 is asked to reload)
      config reset <Key>
      config path                             print the fcitx5 config file

    Options: --file <path> (dict: other file; config: other file), --no-reload (config)
    """

    public static func run(_ arguments: [String], environment env: CtlEnvironment) -> Int32 {
        var args = arguments
        guard let command = args.first else {
            env.err(usage)
            return 2
        }
        args.removeFirst()
        switch command {
        case "dict": return DictCommand(env: env).run(args)
        case "config": return ConfigCommand(env: env).run(args)
        case "help", "--help", "-h":
            env.out(usage)
            return 0
        default:
            env.err("misstypectl: unknown command “\(command)”\n\n" + usage)
            return 2
        }
    }
}

/// Splits `--name value` / `--flag` options from positional arguments.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var error: String?

    init(_ args: [String], valued: Set<String>, flagNames: Set<String> = []) {
        var index = 0
        while index < args.count {
            let item = args[index]
            if item.hasPrefix("--"), item.count > 2 {
                let name = String(item.dropFirst(2))
                if valued.contains(name) {
                    guard index + 1 < args.count else { error = "--\(name) needs a value"; return }
                    options[name] = args[index + 1]
                    index += 1
                } else if flagNames.contains(name) {
                    flags.insert(name)
                } else {
                    error = "unknown option --\(name)"
                    return
                }
            } else {
                positional.append(item)
            }
            index += 1
        }
    }
}
