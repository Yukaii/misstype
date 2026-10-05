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
            return label.count == 1 && USLayout.key(forCharacter: Character(label))?.shifted == false
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
/// `InputSession` already understands — and default chords; a bound chord
/// is rewritten to the canonical event before the session sees it, so the
/// editing rules stay keyed on one set of keys.
public enum KeyAction: String, CaseIterable, Sendable {
    case toggleEnglish
    /// Tab / Shift+Tab: step the list; on a focused word, confirm it and
    /// move on.
    case stepCandidate, stepCandidateBack
    /// Down / Up: move the highlight only.
    case nextCandidate, previousCandidate
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
        case .stepCandidate: return KeyChord(.tab)
        case .stepCandidateBack: return KeyChord(.tab, .shift)
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
    public var defaultChords: [KeyChord] { [canonical] }

    /// Text the canonical event carries (the session swallows printable
    /// keys that type nothing).
    var canonicalText: String? {
        switch self {
        case .toggleEnglish: return " "
        case .stepCandidate, .stepCandidateBack: return "\t"
        case .commit, .commitRaw: return "\r"
        case .cancel: return "\u{1b}"
        case .latinRun: return "`"
        default: return nil
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

    /// Chord → action. Explicit bindings win over defaults; among equals the
    /// first action in `KeyAction.allCases` wins.
    public var table: [KeyChord: KeyAction] {
        var table: [KeyChord: KeyAction] = [:]
        for action in KeyAction.allCases.reversed() where overrides[action] == nil {
            for chord in action.defaultChords { table[chord] = action }
        }
        for action in KeyAction.allCases.reversed() {
            for chord in overrides[action] ?? [] { table[chord] = action }
        }
        return table
    }

    /// Chords bound to more than one action (only the winner fires).
    public var conflicts: Set<KeyChord> {
        var seen: [KeyChord: Int] = [:]
        for action in KeyAction.allCases {
            for chord in Set(chords(for: action)) { seen[chord, default: 0] += 1 }
        }
        return Set(seen.filter { $0.value > 1 }.keys)
    }

    public enum Resolution: Equatable, Sendable {
        /// Not a binding: the session handles the event as it is.
        case unchanged
        /// Bound: the session handles this canonical event instead.
        case rewritten(KeyEvent)
        /// A default chord the user removed: the key goes to the application.
        case unbound
    }

    public func resolve(_ event: KeyEvent) -> Resolution {
        guard event.phase == .press else { return .unchanged }
        let chord = KeyChord(event)
        if let action = table[chord] {
            guard chord != action.canonical else { return .unchanged }
            var rewritten = KeyEvent(action.canonical.key, modifiers: action.canonical.modifiers,
                                     text: action.canonicalText, nativeCode: event.nativeCode,
                                     timestamp: event.timestamp)
            if event.modifiers.contains(.capsLock) { rewritten.modifiers.insert(.capsLock) }
            return .rewritten(rewritten)
        }
        guard let removed = KeyAction.allCases.first(where: { $0.defaultChords.contains(chord) }) else {
            return .unchanged
        }
        // Without its toggle binding Shift+Space is a plain Space.
        if removed == .toggleEnglish {
            var plain = event
            plain.modifiers.remove(.shift)
            return .rewritten(plain)
        }
        return .unbound
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
