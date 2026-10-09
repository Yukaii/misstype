import Foundation

/// Platform-neutral key event the IME adapter hands to the Zig session
/// (`misstype_key_event`): physical keys are named by their US-ANSI
/// unshifted label ("a", "1", ";", "`"), independent of the active layout.
public struct KeyEvent: Equatable, Sendable {
    public enum Key: Hashable, Sendable {
        /// Printable physical key by its US-ANSI unshifted label.
        case character(String)
        case space, enter, tab, backspace, forwardDelete, escape
        case left, right, up, down
        case pageUp, pageDown
        /// Left or right Shift on its own (lone-Shift tap toggles 中/英).
        case shift(ShiftSide)
        /// Any other bare modifier: never text, consumed without committing.
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
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        public static let capsLock = Modifiers(rawValue: 1 << 4)
    }

    public var key: Key
    public var phase: Phase
    /// Modifier state AFTER this event.
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

public struct KeyResult: Equatable, Sendable {
    public var consumed: Bool
    public var commit: String?
    public var beep: Bool
    public var modeChanged: Bool
    public var latinToggled: Bool

    public init(consumed: Bool, commit: String? = nil, beep: Bool = false,
                modeChanged: Bool = false, latinToggled: Bool = false) {
        self.consumed = consumed
        self.commit = commit
        self.beep = beep
        self.modeChanged = modeChanged
        self.latinToggled = latinToggled
    }
}

/// What the host draws: marked text, candidate panel, phrase mark.
public struct SessionView: Equatable, Sendable {
    public var preedit: String
    /// UTF-16 offset of the caret in `preedit`.
    public var caret: Int
    public var candidates: [String]
    public var selected: Int
    /// Labels shown beside the visible rows.
    public var selectionKeys: [String]
    public var keysActive: Bool
    public var showsCandidates: Bool
    public var mark: Mark?
    public var pageSize: Int
    /// Word boundaries of `preedit` as contiguous UTF-16 ranges (empty = draw
    /// one segment).
    public var segments: [Range<Int>]
    /// The syllable cursor's word (one of `segments`), nil outside cursor mode.
    public var focus: Range<Int>?

    public init(preedit: String, caret: Int, candidates: [String], selected: Int,
                selectionKeys: [String], keysActive: Bool, showsCandidates: Bool,
                mark: Mark? = nil, pageSize: Int = SelectionKeys.defaultPageSize,
                segments: [Range<Int>] = [], focus: Range<Int>? = nil) {
        self.preedit = preedit
        self.caret = caret
        self.candidates = candidates
        self.selected = selected
        self.selectionKeys = selectionKeys
        self.keysActive = keysActive
        self.showsCandidates = showsCandidates
        self.mark = mark
        self.pageSize = pageSize
        self.segments = segments
        self.focus = focus
    }

    /// A marked span of the converted text, offered to the user dictionary.
    public struct Mark: Equatable, Sendable {
        public enum Action: Equatable, Sendable {
            case add, remove, tooShort, tooLong, unavailable
        }
        public var range: Range<Int>
        public var text: String
        public var reading: String
        public var action: Action

        public init(range: Range<Int>, text: String, reading: String, action: Action) {
            self.range = range
            self.text = text
            self.reading = reading
            self.action = action
        }
    }

    public static let empty = SessionView(preedit: "", caret: 0, candidates: [], selected: 0,
                                          selectionKeys: [], keysActive: false, showsCandidates: false)
}

/// `text` with a marker at a UTF-16 caret offset (dev traces).
public func preeditWithCursor(_ text: String, caretUTF16 caret: Int, marker: Character = "|") -> String {
    let units = text.utf16
    let clamped = max(0, min(caret, units.count))
    let utf16Index = units.index(units.startIndex, offsetBy: clamped)
    if let index = String.Index(utf16Index, within: text) {
        return String(text[..<index]) + String(marker) + String(text[index...])
    }
    return text + String(marker)
}
