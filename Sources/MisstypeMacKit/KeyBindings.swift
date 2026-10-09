import Foundation

/// A key plus the modifiers held with it, as a user binds it. Caps Lock is
/// never part of a chord. Text form (`description`, `init?(_:)`):
/// modifiers `ctrl+alt+shift+cmd+` in that order, then the key: a physical
/// label (`j`, `;`, `` ` ``; `comma` for `,`, the list separator) or a
/// name (`space`, `enter`, `tab`, `escape`, `left`, `right`, `up`, `down`,
/// `pageup`, `pagedown`).
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public var key: KeyEvent.Key
    public var modifiers: KeyEvent.Modifiers

    public init(_ key: KeyEvent.Key, _ modifiers: KeyEvent.Modifiers = []) {
        self.key = key
        self.modifiers = modifiers.intersection(Self.chordModifiers)
    }

    public init(_ event: KeyEvent) {
        self.init(event.key, event.modifiers)
    }

    static let chordModifiers: KeyEvent.Modifiers = [.control, .option, .shift, .command]
    /// Printable keys by their unshifted US glyph (a-z, digits, punctuation).
    private static let unshiftedGlyphs = Set("abcdefghijklmnopqrstuvwxyz1234567890-=[];'`\\,./")
    private static let modifierNames: [(KeyEvent.Modifiers, String)] = [
        (.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "cmd"),
    ]
    private static let keyNames: [(KeyEvent.Key, String)] = [
        (.space, "space"), (.enter, "enter"), (.tab, "tab"), (.escape, "escape"),
        (.left, "left"), (.right, "right"), (.up, "up"), (.down, "down"),
        (.pageUp, "pageup"), (.pageDown, "pagedown"),
    ]

    /// Keys a binding may use. Editing keys and bare modifiers are not
    /// bindable; a printable key needs Control, Option or Command, since
    /// alone or with Shift it types Zhuyin, capitals or symbols.
    public var isBindable: Bool {
        switch key {
        case .character(let label):
            return label.count == 1 && Self.unshiftedGlyphs.contains(Character(label))
                && !modifiers.isDisjoint(with: [.control, .option, .command])
        case .space, .enter, .tab, .escape, .left, .right, .up, .down, .pageUp, .pageDown:
            return true
        case .backspace, .forwardDelete, .shift, .modifier, .other:
            return false
        }
    }

    public var description: String {
        let mods = Self.modifierNames.filter { modifiers.contains($0.0) }.map(\.1)
        let name: String
        if case .character(let label) = key {
            name = label == "," ? "comma" : label
        } else {
            name = Self.keyNames.first(where: { $0.0 == key })?.1 ?? "?"
        }
        return (mods + [name]).joined(separator: "+")
    }

    /// Parses the text form; nil for anything unknown or not bindable.
    public init?(_ text: String) {
        var parts = text.trimmingCharacters(in: .whitespaces).lowercased().components(separatedBy: "+")
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var modifiers: KeyEvent.Modifiers = []
        for part in parts {
            guard let modifier = Self.modifierNames.first(where: { $0.1 == part })?.0 else { return nil }
            modifiers.insert(modifier)
        }
        let key: KeyEvent.Key
        if let named = Self.keyNames.first(where: { $0.1 == last })?.0 {
            key = named
        } else if last == "comma" {
            key = .character(",")
        } else if last.count == 1 {
            key = .character(last)
        } else {
            return nil
        }
        self.init(key, modifiers)
        guard isBindable else { return nil }
    }
}

/// IME actions a user can rebind. Each has a canonical key event — the one
/// the session understands — and default chords; the Zig core rewrites a
/// bound chord to the canonical event (`misstype_engine_set_key_bindings`).
/// This type only edits and serializes the bindings the preferences show.
public enum KeyAction: String, CaseIterable, Sendable {
    case toggleEnglish
    /// Down / Up: move the highlight one row.
    case nextCandidate, previousCandidate
    /// Tab / PageDown and Shift+Tab / PageUp: one page at a time.
    case nextPage, previousPage
    case cursorBack, cursorForward
    case markBack, markForward
    case commit, commitRaw
    case cancel
    case latinRun

    /// The event the session acts on.
    public var canonical: KeyChord {
        switch self {
        case .toggleEnglish: return KeyChord(.space, .shift)
        case .nextCandidate: return KeyChord(.down)
        case .previousCandidate: return KeyChord(.up)
        case .nextPage: return KeyChord(.pageDown)
        case .previousPage: return KeyChord(.pageUp)
        case .cursorBack: return KeyChord(.left)
        case .cursorForward: return KeyChord(.right)
        case .markBack: return KeyChord(.left, .shift)
        case .markForward: return KeyChord(.right, .shift)
        case .commit: return KeyChord(.enter)
        case .commitRaw: return KeyChord(.enter, .shift)
        case .cancel: return KeyChord(.escape)
        case .latinRun: return KeyChord(.character("`"))
        }
    }

    /// Chords that trigger the action out of the box.
    public var defaultChords: [KeyChord] {
        switch self {
        case .nextPage: return [KeyChord(.tab), KeyChord(.pageDown)]
        case .previousPage: return [KeyChord(.tab, .shift), KeyChord(.pageUp)]
        default: return [canonical]
        }
    }
}

/// The user's bindings: per action, either the defaults or an explicit list
/// (empty = unbound). Text form, one action per line, `#` comments:
///
///     nextCandidate = tab, ctrl+n
///     latinRun =
public struct KeyBindings: Equatable, Sendable {
    /// Actions the user changed; the rest use `KeyAction.defaultChords`.
    public var overrides: [KeyAction: [KeyChord]]

    public init(overrides: [KeyAction: [KeyChord]] = [:]) {
        self.overrides = overrides
    }

    public func chords(for action: KeyAction) -> [KeyChord] {
        overrides[action] ?? action.defaultChords
    }

    /// Chords bound to more than one action (only the winner fires).
    public var conflicts: Set<KeyChord> {
        var seen: [KeyChord: Int] = [:]
        for action in KeyAction.allCases {
            for chord in Set(chords(for: action)) { seen[chord, default: 0] += 1 }
        }
        return Set(seen.filter { $0.value > 1 }.keys)
    }

    public var serialized: String {
        KeyAction.allCases.compactMap { action in
            overrides[action].map { "\(action.rawValue) = " + $0.map(\.description).joined(separator: ", ") }
        }.joined(separator: "\n")
    }

    /// Unknown actions and chords are skipped, never fatal.
    public static func parse(_ text: String) -> KeyBindings {
        var overrides: [KeyAction: [KeyChord]] = [:]
        for line in text.components(separatedBy: .newlines) {
            let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let action = KeyAction(rawValue: parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            var chords: [KeyChord] = []
            for item in parts[1].split(separator: ",") {
                if let chord = KeyChord(String(item)), !chords.contains(chord) { chords.append(chord) }
            }
            overrides[action] = chords
        }
        return KeyBindings(overrides: overrides)
    }
}
