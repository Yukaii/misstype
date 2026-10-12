import Foundation

/// The colors of the user's own candidate-panel theme, as the text the
/// Settings editor shows and `defaults` stores. Four slots (background, text,
/// selection key, highlighted row) for light and for dark. Anything
/// unparsable falls back to that slot's default at read time, so a half-typed
/// hex never breaks the panel (`resolved`), while paste/import use `init?(strict:)`.
///
/// Text form: `bg,text,key,highlight` when light and dark share colors (the
/// only form before 2026-10-12, still read), else `light|dark` with two such lists.
public struct ThemeColors: Equatable, Sendable {
    public static let slotCount = 4
    public static let defaultHex = ["1e1e2e", "cdd6f4", "cba6f7", "313244"]
    public static let defaultText = defaultHex.joined(separator: ",")

    /// Slot values as typed, without "#".
    public private(set) var light: [String]
    public private(set) var dark: [String]
    /// One set of colors for both appearances. While on, edits write both.
    public var linked: Bool

    public init(text: String = defaultText) {
        let halves = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        light = Self.slots(String(halves.first ?? ""))
        if halves.count == 2 {
            dark = Self.slots(String(halves[1]))
            linked = false
        } else {
            dark = light
            linked = true
        }
    }

    /// Every slot of every half must be a hex color; nil otherwise.
    public init?(strict text: String) {
        let halves = text.split(separator: "|", omittingEmptySubsequences: false)
        guard halves.count <= 2 else { return nil }
        for half in halves {
            let parts = half.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == Self.slotCount, parts.allSatisfy({ Self.parse(String($0)) != nil }) else { return nil }
        }
        self.init(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public init(light: [UInt32], dark: [UInt32]) {
        self.light = Self.slots(light.map(Self.hexString).joined(separator: ","))
        self.dark = Self.slots(dark.map(Self.hexString).joined(separator: ","))
        linked = false
    }

    private static func slots(_ list: String) -> [String] {
        let parts = list.split(separator: ",", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        return defaultHex.indices.map { parts.indices.contains($0) ? parts[$0] : defaultHex[$0] }
    }

    public var text: String {
        linked ? light.joined(separator: ",") : light.joined(separator: ",") + "|" + dark.joined(separator: ",")
    }

    public func hex(_ slot: Int, dark isDark: Bool) -> String { isDark ? dark[slot] : light[slot] }

    /// Writes one slot of the shown half, and of the other too while linked.
    public mutating func set(_ slot: Int, dark isDark: Bool, to value: String) {
        let clean = value.filter { $0 != "," && $0 != "|" }
        if linked || !isDark { light[slot] = clean }
        if linked || isDark { dark[slot] = clean }
    }

    /// Linking keeps the half currently shown.
    public mutating func setLinked(_ on: Bool, keeping isDark: Bool) {
        if on { if isDark { light = dark } else { dark = light } }
        linked = on
    }

    public func isValid(_ slot: Int, dark isDark: Bool) -> Bool {
        Self.parse(hex(slot, dark: isDark)) != nil
    }

    /// RGB of a slot, the default when what was typed is not a color.
    public func resolved(_ slot: Int, dark isDark: Bool) -> UInt32 {
        Self.parse(hex(slot, dark: isDark)) ?? Self.parse(Self.defaultHex[slot]) ?? 0
    }

    /// 3- or 6-digit hex, optional leading "#"; nil when it is neither.
    public static func parse(_ string: String) -> UInt32? {
        var digits = string.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }

    public static func hexString(_ rgb: UInt32) -> String {
        String(format: "%06x", rgb & 0xffffff)
    }
}
