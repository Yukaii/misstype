import Cocoa
import MisstypeCore

/// User preferences: UserDefaults-backed, read live (no caching, so the
/// panel and `defaults write` take effect on the next keystroke).
/// - fuzzyRepair: tiered edit repair (transpose/neighbor/phonetic/insert/
///   delete). Off = exact + toneless readings only.
/// - toneTolerance: wrong-tone variants stay viable with a penalty. Off =
///   explicit tones must match exactly (toneless input still decodes via
///   toneless variants — strictness applies to asserted tones).
/// - candidateKeys: selection keys, active only in selection mode (Down/Tab
///   or the syllable cursor); they are Zhuyin keys while typing.
/// - jevEnabled / jevRichContext / jevApiKey / jevModel: Jev gateway
///   assistance. Default OFF (offline baseline): the adapter never calls the
///   network unless the user explicitly enables it AND provides a key.
///   Rich context additionally gates the alignment/diff/contract metadata.
enum MisstypePrefs {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "MisstypeFuzzyRepair": true,
            "MisstypeToneTolerance": true,
            "MisstypeCandidateKeys": "asdfghjkl;",
            "MisstypeUserLearning": true,
            "MisstypeJevEnabled": false,
            "MisstypeJevRichContext": false,
            "MisstypeJevApiKey": "",
            "MisstypeJevModel": JevConfig.defaultModel,
            "MisstypeShiftToggle": true,
            "MisstypeAutoCommitSyllables": 24,
            "MisstypeAutoShowCandidates": false,
            "MisstypeReturnConfirmsSelection": true,
            "MisstypeMixedEnglish": false,
            "MisstypeCandidatesPerPage": SelectionKeys.defaultPageSize,
            "MisstypeKeyBindings": "",
            "MisstypeCursorCandidates": CursorCandidates.covering.rawValue,
            "MisstypeCandidateFontSize": PanelStyle.defaultFontSize,
            "MisstypePanelAppearance": PanelStyle.Appearance.system.rawValue,
            "MisstypePanelTheme": PanelTheme.system.rawValue,
            "MisstypeCustomTheme": CustomTheme.defaultText,
            "MisstypeCandidateGrid": false,
        ])
    }

    /// Key bindings in `KeyBindings` text form (empty = all defaults).
    /// Parsed once per distinct value, since it is read every keystroke.
    static var keyBindings: KeyBindings {
        get {
            let text = UserDefaults.standard.string(forKey: "MisstypeKeyBindings") ?? ""
            if let cached = bindingsCache, cached.text == text { return cached.bindings }
            let bindings = KeyBindings.parse(text)
            bindingsCache = (text, bindings)
            return bindings
        }
        set { UserDefaults.standard.set(newValue.serialized, forKey: "MisstypeKeyBindings") }
    }
    private static var bindingsCache: (text: String, bindings: KeyBindings)?


    /// Which words the syllable cursor (←/→) lists.
    static var cursorCandidates: CursorCandidates {
        get { CursorCandidates(rawValue: UserDefaults.standard.string(forKey: "MisstypeCursorCandidates") ?? "") ?? .covering }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "MisstypeCursorCandidates") }
    }

    /// Candidates per page (clamped to `SelectionKeys.pageSizes`).
    static var candidatesPerPage: Int {
        get { SelectionKeys.clampPageSize(UserDefaults.standard.integer(forKey: "MisstypeCandidatesPerPage")) }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeCandidatesPerPage") }
    }

    /// Candidate panel look, read each time the panel redraws.
    static var panelStyle: PanelStyle {
        let defaults = UserDefaults.standard
        return PanelStyle(
            fontSize: PanelStyle.clampFontSize(defaults.double(forKey: "MisstypeCandidateFontSize")),
            appearance: PanelStyle.Appearance(rawValue: defaults.string(forKey: "MisstypePanelAppearance") ?? "") ?? .system,
            theme: PanelTheme(rawValue: defaults.string(forKey: "MisstypePanelTheme") ?? "") ?? .system,
            grid: defaults.bool(forKey: "MisstypeCandidateGrid"))
    }

    /// Lone-Shift-tap toggles 中/英 (default on; Shift+Space always works).
    /// Kill-switch for clients that misdeliver modifier events.
    static var shiftToggle: Bool {
        get { UserDefaults.standard.bool(forKey: "MisstypeShiftToggle") }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeShiftToggle") }
    }

    /// Candidate panel opens by itself while composing (default off: it
    /// shows once Tab/Down/Up or the syllable cursor starts selecting).
    static var autoShowCandidates: Bool {
        get { UserDefaults.standard.bool(forKey: "MisstypeAutoShowCandidates") }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeAutoShowCandidates") }
    }

    /// Return during candidate selection confirms the pick without
    /// committing (default on); off = Return commits the whole composition.
    static var returnConfirmsSelection: Bool {
        get { UserDefaults.standard.bool(forKey: "MisstypeReturnConfirmsSelection") }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeReturnConfirmsSelection") }
    }

    /// Bare keys that spell an English word (or a one-letter typo of one) are
    /// offered as English and adopted when clearly better than the Chinese
    /// reading. Default off until it has been checked on real typing; needs
    /// `english.tsv` in the app bundle.
    static var mixedEnglish: Bool {
        get { UserDefaults.standard.bool(forKey: "MisstypeMixedEnglish") }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeMixedEnglish") }
    }

    /// Long compositions commit their settled head in chunks once they pass
    /// this many syllables (0 = off). `defaults write` only, no UI yet.
    static var autoCommitSyllables: Int {
        get { max(0, UserDefaults.standard.integer(forKey: "MisstypeAutoCommitSyllables")) }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeAutoCommitSyllables") }
    }

    static var fuzzyRepair: Bool {
        get { UserDefaults.standard.bool(forKey: "MisstypeFuzzyRepair") }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeFuzzyRepair") }
    }

    static var toneTolerance: Bool {
        get { UserDefaults.standard.bool(forKey: "MisstypeToneTolerance") }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeToneTolerance") }
    }

    static var candidateKeys: String {
        get {
            SelectionKeys.sanitize(UserDefaults.standard.string(forKey: "MisstypeCandidateKeys") ?? SelectionKeys.defaultKeys,
                                   pageSize: candidatesPerPage)
        }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeCandidateKeys") }
    }

    /// User phrase learning: ON by default (single-user prototype, local
    /// JSON only — see UserLexicon.defaultURL), opt-out in Preferences or
    /// via `defaults write`. When on, an explicitly picked candidate
    /// (Tab/arrows/digit/click, not separator pinning) is recorded on commit
    /// as (readings → text) with a score bonus next time. No network, no
    /// inference.
    static var userLearning: Bool {
        get { UserDefaults.standard.bool(forKey: "MisstypeUserLearning") }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeUserLearning") }
    }

    static var jevEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "MisstypeJevEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeJevEnabled") }
    }

    static var jevRichContext: Bool {
        get { UserDefaults.standard.bool(forKey: "MisstypeJevRichContext") }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeJevRichContext") }
    }

    /// Gateway key. Stored in UserDefaults for prototype simplicity (a
    /// Keychain move is queued if this graduates beyond experiment); the
    /// value is never logged — only presence is observable.
    static var jevApiKey: String {
        get { UserDefaults.standard.string(forKey: "MisstypeJevApiKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeJevApiKey") }
    }

    static var jevModel: String {
        get { UserDefaults.standard.string(forKey: "MisstypeJevModel") ?? JevConfig.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeJevModel") }
    }

    /// Everything one keystroke reads, snapshotted per event by the session.
    static var sessionSettings: SessionSettings {
        SessionSettings(fuzzyRepair: fuzzyRepair, toneTolerance: toneTolerance,
                        candidateKeys: candidateKeys, userLearning: userLearning,
                        shiftToggle: shiftToggle, jev: jevConfig,
                        autoCommitSyllables: autoCommitSyllables,
                        autoShowCandidates: autoShowCandidates,
                        returnConfirmsSelection: returnConfirmsSelection,
                        mixedEnglish: mixedEnglish,
                        pageSize: candidatesPerPage,
                        keyBindings: keyBindings,
                        cursorCandidates: cursorCandidates)
    }

    /// Live adapter config: explicit enable + key presence gate the attempt;
    /// empty prefs key falls back to AI_GATEWAY_API_KEY env (CLI runs).
    static var jevConfig: JevConfig {
        let model = jevModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return JevConfig(
            enabled: jevEnabled,
            allowRichContext: jevRichContext,
            apiKey: JevConfig.resolveApiKey(preferencesKey: jevApiKey),
            model: model.isEmpty ? JevConfig.defaultModel : model)
    }
}

/// How the candidate panel draws (macOS only: what a key does never depends
/// on it). Font size scales the row height with it.
struct PanelStyle: Equatable {
    enum Appearance: String, CaseIterable {
        case system, light, dark
    }

    static let defaultFontSize: Double = 15
    static let fontSizes: ClosedRange<Double> = 12...24
    static func clampFontSize(_ size: Double) -> Double {
        size == 0 ? defaultFontSize : min(max(size, fontSizes.lowerBound), fontSizes.upperBound)
    }

    var fontSize: Double = defaultFontSize
    var appearance: Appearance = .system
    var theme: PanelTheme = .system
    /// Show every page side by side (up to 4 columns) instead of one list.
    var grid = false
}

/// Color scheme of the candidate panel. Each has a light and a dark
/// palette; `PanelStyle.appearance` (or the system) picks which. `system`
/// uses the macOS semantic colors with a neutral gray highlight.
enum PanelTheme: String, CaseIterable {
    case system, solarized, nord, gruvbox, catppuccin, custom

    struct Palette: Equatable {
        var colors: [NSColor] { [background, text, key, highlight] }
        var background: NSColor
        var text: NSColor
        /// Selection-key labels while they pick, and the page footer.
        var key: NSColor
        /// Labels while the keys still type Zhuyin.
        var dimKey: NSColor
        var highlight: NSColor
    }

    var title: String {
        switch self {
        case .system: return L("Default")
        case .solarized: return "Solarized"
        case .nord: return "Nord"
        case .gruvbox: return "Gruvbox"
        case .catppuccin: return "Catppuccin"
        case .custom: return L("Custom")
        }
    }

    /// Published palette values (Solarized, Nord, Gruvbox, Catppuccin
    /// Latte/Mocha); nil = system colors.
    func palette(dark: Bool) -> Palette? {
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        switch (self, dark) {
        case (.system, _): return nil
        case (.custom, _): return CustomTheme.current.palette
        case (.solarized, false):
            return Palette(background: c(0xfdf6e3), text: c(0x586e75), key: c(0x268bd2), dimKey: c(0x93a1a1), highlight: c(0xeee8d5))
        case (.solarized, true):
            return Palette(background: c(0x002b36), text: c(0x93a1a1), key: c(0x268bd2), dimKey: c(0x586e75), highlight: c(0x073642))
        case (.nord, false):
            return Palette(background: c(0xeceff4), text: c(0x2e3440), key: c(0x5e81ac), dimKey: c(0x9aa3b5), highlight: c(0xd8dee9))
        case (.nord, true):
            return Palette(background: c(0x2e3440), text: c(0xeceff4), key: c(0x88c0d0), dimKey: c(0x4c566a), highlight: c(0x434c5e))
        case (.gruvbox, false):
            return Palette(background: c(0xfbf1c7), text: c(0x3c3836), key: c(0xaf3a03), dimKey: c(0xa89984), highlight: c(0xebdbb2))
        case (.gruvbox, true):
            return Palette(background: c(0x282828), text: c(0xebdbb2), key: c(0xfabd2f), dimKey: c(0x665c54), highlight: c(0x3c3836))
        case (.catppuccin, false):
            return Palette(background: c(0xeff1f5), text: c(0x4c4f69), key: c(0x8839ef), dimKey: c(0x9ca0b0), highlight: c(0xccd0da))
        case (.catppuccin, true):
            return Palette(background: c(0x1e1e2e), text: c(0xcdd6f4), key: c(0xcba6f7), dimKey: c(0x6c7086), highlight: c(0x313244))
        }
    }
}

/// The user's own panel colors: four hex values (background, text, selection
/// key, highlighted row) stored as one "bg,text,key,highlight" string and
/// used for both light and dark. Anything unparsable falls back to the
/// default value of that slot, so a half-typed hex never breaks the panel.
struct CustomTheme: Equatable {
    static let defaultText = "1e1e2e,cdd6f4,cba6f7,313244"
    static let userDefaultsKey = "MisstypeCustomTheme"

    /// Background, text, key, highlight, as typed (no "#").
    var hex: [String]

    static var current: CustomTheme {
        CustomTheme(text: UserDefaults.standard.string(forKey: userDefaultsKey) ?? defaultText)
    }

    init(text: String) {
        let defaults = Self.defaultText.split(separator: ",").map(String.init)
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        hex = defaults.indices.map { parts.indices.contains($0) ? parts[$0] : defaults[$0] }
    }

    var text: String { hex.joined(separator: ",") }

    /// 3- or 6-digit hex, optional leading "#"; nil when it is neither.
    static func parse(_ string: String) -> UInt32? {
        var digits = string.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }

    var palette: PanelTheme.Palette {
        let fallback = Self.defaultText.split(separator: ",").map { Self.parse(String($0)) ?? 0 }
        func color(_ i: Int) -> NSColor {
            let v = Self.parse(hex[i]) ?? fallback[i]
            return NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        let text = color(1), background = color(0)
        // Dim labels (Zhuyin still typing) are the text color faded into the background.
        let dim = text.blended(withFraction: 0.55, of: background) ?? text
        return PanelTheme.Palette(background: background, text: text, key: color(2), dimKey: dim, highlight: color(3))
    }
}
