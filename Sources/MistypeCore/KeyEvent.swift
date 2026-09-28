import Foundation

/// Platform-neutral key event: the only input `InputSession` understands.
/// Adapters translate native events (NSEvent, fcitx5/IBus key events) into
/// this; nothing past the adapter knows a platform keycode.
///
/// Physical keys are named by their US-ANSI unshifted label ("a", "1", ";",
/// "`"), independent of the user's active Latin layout: the Zhuyin (大千)
/// layout is positional, so adapters map scancodes, never layout characters.
public struct KeyEvent: Equatable, Sendable {
    public enum Key: Hashable, Sendable {
        /// Printable physical key by its US-ANSI unshifted label.
        case character(String)
        case space, enter, tab, backspace, forwardDelete, escape
        case left, right, up, down
        /// Left or right Shift on its own (lone-Shift tap toggles 中/英).
        case shift(ShiftSide)
        /// Any other bare modifier (Control, Option/Alt, Command/Super,
        /// Caps Lock, Fn): never text, consumed without committing.
        case modifier
        /// Anything else (function keys, Home/End, …): commits, passes through.
        case other
    }
    public enum ShiftSide: Hashable, Sendable { case left, right }
    /// `.release` covers key-up AND modifier-only transitions (macOS
    /// flagsChanged): both only feed lone-Shift tap tracking.
    public enum Phase: Hashable, Sendable { case press, release }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        /// Option (macOS) / Alt.
        public static let option = Modifiers(rawValue: 1 << 2)
        /// Command (macOS) / Super.
        public static let command = Modifiers(rawValue: 1 << 3)
        public static let capsLock = Modifiers(rawValue: 1 << 4)
    }

    public var key: Key
    public var phase: Phase
    /// Modifier state AFTER this event (a Shift press carries `.shift`, its
    /// release does not) — the tap tracker reads transitions from it.
    public var modifiers: Modifiers
    /// Text the key types in the user's layout (case included), nil if none.
    public var text: String?
    /// Native key code for the diagnostic trace only (codes, never text).
    public var nativeCode: Int?
    /// Seconds on any monotonic clock (tap timing); nil means now.
    public var timestamp: TimeInterval?

    public init(_ key: Key, phase: Phase = .press, modifiers: Modifiers = [],
                text: String? = nil, nativeCode: Int? = nil, timestamp: TimeInterval? = nil) {
        self.key = key
        self.phase = phase
        self.modifiers = modifiers
        self.text = text
        self.nativeCode = nativeCode
        self.timestamp = timestamp
    }
}

extension KeyEvent.Key {
    /// Zhuyin keyboard label (a Bopomofo symbol or tone key, space = first
    /// tone), nil for every other key.
    public var zhuyinLabel: String? {
        switch self {
        case .space:
            return " "
        case .character(let label):
            return ZhuyinKeyboard.symbols[label] != nil || ZhuyinKeyboard.tones[label] != nil ? label : nil
        default:
            return nil
        }
    }

    /// Label of a letter key ("a"…"z"), nil otherwise.
    var letterLabel: String? {
        guard case .character(let label) = self, label.count == 1,
              let scalar = label.unicodeScalars.first,
              CharacterSet.letters.contains(scalar) else { return nil }
        return label
    }

    var shiftSide: KeyEvent.ShiftSide? {
        if case .shift(let side) = self { return side }
        return nil
    }
}

/// macOS virtual key codes (ANSI positions) → neutral keys. Pure data, kept
/// in the core so it is unit-tested on every platform the core builds on.
public enum MacKeyCode {
    public static let labels: [Int: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o",
        32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
    ]

    public static func key(_ code: Int) -> KeyEvent.Key {
        if let label = labels[code] { return .character(label) }
        switch code {
        case 49: return .space
        case 36, 76: return .enter // Return, keypad Enter
        case 48: return .tab
        case 51: return .backspace
        case 117: return .forwardDelete
        case 53: return .escape
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 56: return .shift(.left)
        case 60: return .shift(.right)
        // Command 55/54, Caps 57, Option 58/61, Control 59/62, Fn 63, Help 114.
        case 55, 54, 57, 58, 61, 59, 62, 63, 114: return .modifier
        default: return .other
        }
    }
}

/// Linux evdev key codes (from `/usr/include/linux/input-event-codes.h`) →
/// neutral keys. The same label set as `MacKeyCode` so unit tests can assert
/// parity. X11/fcitx5 keycodes are evdev + 8.
public enum EvdevKeyCode {
    public static let labels: [Int: String] = [
        // Number row (KEY_1…KEY_0)
        2: "1", 3: "2", 4: "3", 5: "4", 6: "5",
        7: "6", 8: "7", 9: "8", 10: "9", 11: "0",
        12: "-", 13: "=",
        // QWERTY row (KEY_Q…KEY_P)
        16: "q", 17: "w", 18: "e", 19: "r", 20: "t",
        21: "y", 22: "u", 23: "i", 24: "o", 25: "p",
        26: "[", 27: "]",
        // Home row (KEY_A…KEY_L)
        30: "a", 31: "s", 32: "d", 33: "f", 34: "g",
        35: "h", 36: "j", 37: "k", 38: "l", 39: ";",
        40: "'",
        // Bottom row (KEY_Z…KEY_M)
        41: "`",  // KEY_GRAVE
        44: "z", 45: "x", 46: "c", 47: "v", 48: "b",
        49: "n", 50: "m", 51: ",", 52: ".", 53: "/",
        // Backslash (KEY_BACKSLASH)
        43: "\\",
    ]

    public static func key(_ code: Int) -> KeyEvent.Key {
        if let label = labels[code] { return .character(label) }
        switch code {
        case 57: return .space
        case 28, 96: return .enter // Return, keypad Enter
        case 15: return .tab
        case 14: return .backspace
        case 111: return .forwardDelete
        case 1: return .escape
        case 105: return .left
        case 106: return .right
        case 103: return .up
        case 108: return .down
        case 42: return .shift(.left)
        case 54: return .shift(.right)
        // Ctrl: 29, 97; Alt: 56, 100; Meta/Super: 125, 126; Caps Lock: 58
        case 29, 97, 56, 100, 125, 126, 58: return .modifier
        default: return .other
        }
    }
}

/// US-ANSI layout character → (physical key, shifted) for events without a scancode.
/// Derived from the label set; lowercase/unshifted glyphs → shifted == false.
/// Uppercase letters and shifted glyphs → shifted == true.
public enum USLayout {
    public struct KeyMapping: Equatable, Sendable {
        public let key: KeyEvent.Key
        public let shifted: Bool
        public init(key: KeyEvent.Key, shifted: Bool) {
            self.key = key
            self.shifted = shifted
        }
    }

    private static let unshifted: [Character: KeyMapping] = {
        var map: [Character: KeyMapping] = [:]
        // Letters a-z → character keys, unshifted
        for ch in "abcdefghijklmnopqrstuvwxyz" {
            map[ch] = KeyMapping(key: .character(String(ch)), shifted: false)
        }
        // Digits and unshifted symbols
        let unshiftedSymbols: [(Character, String)] = [
            ("1", "1"), ("2", "2"), ("3", "3"), ("4", "4"), ("5", "5"),
            ("6", "6"), ("7", "7"), ("8", "8"), ("9", "9"), ("0", "0"),
            ("-", "-"), ("=", "="),
            ("[", "["), ("]", "]"),
            (";", ";"), ("'", "'"),
            ("`", "`"),
            ("\\", "\\"),
            (",", ","), (".", "."), ("/", "/"),
        ]
        for (ch, label) in unshiftedSymbols {
            map[ch] = KeyMapping(key: .character(label), shifted: false)
        }
        // Space
        map[" "] = KeyMapping(key: .space, shifted: false)
        return map
    }()

    private static let shifted: [Character: KeyMapping] = {
        var map: [Character: KeyMapping] = [:]
        // Uppercase letters A-Z → character keys, shifted
        for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            map[ch] = KeyMapping(key: .character(String(ch).lowercased()), shifted: true)
        }
        // Shifted symbols
        let shiftedSymbols: [(Character, String)] = [
            ("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"), ("%", "5"),
            ("^", "6"), ("&", "7"), ("*", "8"), ("(", "9"), (")", "0"),
            ("_", "-"), ("+", "="),
            ("{", "["), ("}", "]"),
            (":", ";"), ("\"", "'"),
            ("~", "`"),
            ("|", "\\"),
            ("<", ","), (">", "."), ("?", "/"),
        ]
        for (ch, label) in shiftedSymbols {
            map[ch] = KeyMapping(key: .character(label), shifted: true)
        }
        return map
    }()

    public static func key(forCharacter character: Character) -> KeyMapping? {
        if let result = unshifted[character] { return result }
        if let result = shifted[character] { return result }
        return nil
    }
}
