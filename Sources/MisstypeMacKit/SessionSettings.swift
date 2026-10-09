import Foundation

/// Candidates per page and selection keys. The Zig core owns the editing
/// rules; this is only what the preferences UI needs to validate input.
public enum SelectionKeys {
    public static let defaultKeys = "asdfghjkl;"
    /// Candidates per page: default and the range a preference may pick.
    public static let defaultPageSize = 8
    public static let pageSizes = 4...10
    public static func clampPageSize(_ size: Int) -> Int {
        min(max(size, pageSizes.lowerBound), pageSizes.upperBound)
    }

    /// Keys a selection key may be: every Zhuyin symbol and tone key (never space).
    private static let known = Set("1qaz2wsxedcrfvtgbyhnujm8ik,9ol.0p;/-5" + "3467")

    /// Preferences input -> usable keys: lowercased, distinct, only keys the
    /// keyboard map knows (never space), capped at one page; empty -> default.
    public static func sanitize(_ input: String, pageSize: Int = 8) -> String {
        var seen = Set<Character>()
        let keys = input.lowercased().filter { known.contains($0) && seen.insert($0).inserted }.prefix(pageSize)
        return keys.isEmpty ? String(defaultKeys.prefix(pageSize)) : String(keys)
    }

    /// Labels shown beside the visible rows.
    public static func labels(keys: String, pageSize: Int = 8) -> [String] {
        Array(keys).prefix(pageSize).map(String.init)
    }
}

/// How readily keyboard slips are repaired (`misstype_engine_set_repair_strength`).
public enum RepairStrength: String, CaseIterable, Codable, Sendable {
    case off
    case light
    case standard
    case strong

    /// The C ABI level: 0 off, 1 light, 2 standard, 3 strong.
    public var level: Int32 {
        switch self {
        case .off: return 0
        case .light: return 1
        case .standard: return 2
        case .strong: return 3
        }
    }
}

/// Which words the syllable cursor lists (`misstype_cursor_candidates`).
public enum CursorCandidates: String, CaseIterable, Sendable {
    case covering
    case endingAt
    case beginningAt

    public var level: Int32 {
        switch self {
        case .covering: return 0
        case .endingAt: return 1
        case .beginningAt: return 2
        }
    }
}

/// Live preferences the IME hands to the Zig engine on every keystroke, so a
/// preference flip applies on the next key.
public struct SessionSettings: Equatable, Sendable {
    public var repairStrength: RepairStrength
    public var toneTolerance: Bool
    /// Selection keys (sanitized; see `SelectionKeys.sanitize`).
    public var candidateKeys: String
    public var userLearning: Bool
    /// Lone-Shift tap toggles 中/英 (Shift+Space always does).
    public var shiftToggle: Bool
    public var autoCommitSyllables: Int
    public var autoShowCandidates: Bool
    public var returnConfirmsSelection: Bool
    public var mixedEnglish: Bool
    public var pageSize: Int {
        get { pageSizeValue }
        set { pageSizeValue = SelectionKeys.clampPageSize(newValue) }
    }
    private var pageSizeValue: Int
    public var keyBindings: KeyBindings
    public var cursorCandidates: CursorCandidates
    /// Personal channel model: learn which keys this user swaps.
    public var channelLearning: Bool

    public var fuzzyRepair: Bool { repairStrength != .off }

    public init(repairStrength: RepairStrength = .standard, toneTolerance: Bool = true,
                candidateKeys: String = SelectionKeys.defaultKeys, userLearning: Bool = true,
                shiftToggle: Bool = true,
                autoCommitSyllables: Int = 24, autoShowCandidates: Bool = true,
                returnConfirmsSelection: Bool = false, mixedEnglish: Bool = true,
                pageSize: Int = SelectionKeys.defaultPageSize,
                keyBindings: KeyBindings = KeyBindings(),
                cursorCandidates: CursorCandidates = .covering,
                channelLearning: Bool = false) {
        self.repairStrength = repairStrength
        self.toneTolerance = toneTolerance
        self.candidateKeys = candidateKeys
        self.userLearning = userLearning
        self.shiftToggle = shiftToggle
        self.autoCommitSyllables = autoCommitSyllables
        self.autoShowCandidates = autoShowCandidates
        self.returnConfirmsSelection = returnConfirmsSelection
        self.mixedEnglish = mixedEnglish
        self.pageSizeValue = SelectionKeys.clampPageSize(pageSize)
        self.keyBindings = keyBindings
        self.cursorCandidates = cursorCandidates
        self.channelLearning = channelLearning
    }
}
