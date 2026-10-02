import Cocoa
import MistypeCore

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
enum MistypePrefs {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "MistypeFuzzyRepair": true,
            "MistypeToneTolerance": true,
            "MistypeCandidateKeys": "asdfghjkl;",
            "MistypeUserLearning": true,
            "MistypeJevEnabled": false,
            "MistypeJevRichContext": false,
            "MistypeJevApiKey": "",
            "MistypeJevModel": JevConfig.defaultModel,
            "MistypeShiftToggle": true,
            "MistypeAutoCommitSyllables": 24,
            "MistypeCandidateStyle": CandidateStyle.auto.rawValue,
        ])
    }

    /// How the candidate list is shown. `auto` draws it inline after the
    /// preedit (no window) and falls back to our panel in apps that cannot
    /// show it (`InlineSupport`); the others force one way.
    enum CandidateStyle: String, CaseIterable {
        case auto, inline, panel
    }

    static var candidateStyle: CandidateStyle {
        get { CandidateStyle(rawValue: UserDefaults.standard.string(forKey: "MistypeCandidateStyle") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "MistypeCandidateStyle") }
    }

    /// Lone-Shift-tap toggles 中/英 (default on; Shift+Space always works).
    /// Kill-switch for clients that misdeliver modifier events.
    static var shiftToggle: Bool {
        get { UserDefaults.standard.bool(forKey: "MistypeShiftToggle") }
        set { UserDefaults.standard.set(newValue, forKey: "MistypeShiftToggle") }
    }

    /// Long compositions commit their settled head in chunks once they pass
    /// this many syllables (0 = off). `defaults write` only, no UI yet.
    static var autoCommitSyllables: Int {
        get { max(0, UserDefaults.standard.integer(forKey: "MistypeAutoCommitSyllables")) }
        set { UserDefaults.standard.set(newValue, forKey: "MistypeAutoCommitSyllables") }
    }

    static var fuzzyRepair: Bool {
        get { UserDefaults.standard.bool(forKey: "MistypeFuzzyRepair") }
        set { UserDefaults.standard.set(newValue, forKey: "MistypeFuzzyRepair") }
    }

    static var toneTolerance: Bool {
        get { UserDefaults.standard.bool(forKey: "MistypeToneTolerance") }
        set { UserDefaults.standard.set(newValue, forKey: "MistypeToneTolerance") }
    }

    static var candidateKeys: String {
        get { SelectionKeys.sanitize(UserDefaults.standard.string(forKey: "MistypeCandidateKeys") ?? SelectionKeys.defaultKeys) }
        set { UserDefaults.standard.set(newValue, forKey: "MistypeCandidateKeys") }
    }

    /// User phrase learning: ON by default (single-user prototype, local
    /// JSON only — see UserLexicon.defaultURL), opt-out in Preferences or
    /// via `defaults write`. When on, an explicitly picked candidate
    /// (Tab/arrows/digit/click, not separator pinning) is recorded on commit
    /// as (readings → text) with a score bonus next time. No network, no
    /// inference.
    static var userLearning: Bool {
        get { UserDefaults.standard.bool(forKey: "MistypeUserLearning") }
        set { UserDefaults.standard.set(newValue, forKey: "MistypeUserLearning") }
    }

    static var jevEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "MistypeJevEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "MistypeJevEnabled") }
    }

    static var jevRichContext: Bool {
        get { UserDefaults.standard.bool(forKey: "MistypeJevRichContext") }
        set { UserDefaults.standard.set(newValue, forKey: "MistypeJevRichContext") }
    }

    /// Gateway key. Stored in UserDefaults for prototype simplicity (a
    /// Keychain move is queued if this graduates beyond experiment); the
    /// value is never logged — only presence is observable.
    static var jevApiKey: String {
        get { UserDefaults.standard.string(forKey: "MistypeJevApiKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "MistypeJevApiKey") }
    }

    static var jevModel: String {
        get { UserDefaults.standard.string(forKey: "MistypeJevModel") ?? JevConfig.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: "MistypeJevModel") }
    }

    /// Everything one keystroke reads, snapshotted per event by the session.
    static var sessionSettings: SessionSettings {
        SessionSettings(fuzzyRepair: fuzzyRepair, toneTolerance: toneTolerance,
                        candidateKeys: candidateKeys, userLearning: userLearning,
                        shiftToggle: shiftToggle, jev: jevConfig,
                        autoCommitSyllables: autoCommitSyllables)
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
