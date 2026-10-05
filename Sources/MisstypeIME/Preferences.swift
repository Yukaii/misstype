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
            "MisstypeShiftToggleSide": ShiftToggleSide.either.rawValue,
            "MisstypeShiftSpaceToggle": true,
            "MisstypePageKeys": PageKeys.minusEqual.rawValue,
            "MisstypeCursorCandidates": CursorCandidates.covering.rawValue,
            "MisstypeCandidateFontSize": PanelStyle.defaultFontSize,
            "MisstypePanelAppearance": PanelStyle.Appearance.system.rawValue,
            "MisstypeAccentHighlight": false,
        ])
    }

    /// Which lone Shift tap toggles 中/英 (when `shiftToggle` is on).
    static var shiftToggleSide: ShiftToggleSide {
        get { ShiftToggleSide(rawValue: UserDefaults.standard.string(forKey: "MisstypeShiftToggleSide") ?? "") ?? .either }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "MisstypeShiftToggleSide") }
    }

    /// Shift+Space toggles 中/英 (default on); off = it types like Space.
    static var shiftSpaceToggle: Bool {
        get { UserDefaults.standard.bool(forKey: "MisstypeShiftSpaceToggle") }
        set { UserDefaults.standard.set(newValue, forKey: "MisstypeShiftSpaceToggle") }
    }

    /// Keys that turn pages while selecting, besides PageUp/PageDown.
    static var pageKeys: PageKeys {
        get { PageKeys(rawValue: UserDefaults.standard.string(forKey: "MisstypePageKeys") ?? "") ?? .minusEqual }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "MisstypePageKeys") }
    }

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
            accentHighlight: defaults.bool(forKey: "MisstypeAccentHighlight"))
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
                        pageSize: candidatesPerPage, shiftToggleSide: shiftToggleSide,
                        shiftSpaceToggle: shiftSpaceToggle, pageKeys: pageKeys,
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
    /// Highlight in the system accent color instead of neutral gray.
    var accentHighlight = false
}
