import Foundation

/// Preferences one keystroke is processed under. Adapters read them from
/// their own store (macOS: UserDefaults) — live, per event, never cached, so
/// a preference flip applies on the next keystroke.
public struct SessionSettings: Equatable, Sendable {
    public var fuzzyRepair: Bool
    public var toneTolerance: Bool
    /// Selection keys (sanitized; see `SelectionKeys.sanitize`).
    public var candidateKeys: String
    public var userLearning: Bool
    /// Lone-Shift tap toggles 中/英 (Shift+Space always does).
    public var shiftToggle: Bool
    public var jev: JevConfig
    /// A composition longer than this many syllables commits its settled
    /// head in chunks while typing continues (0 = never). Bounds per-key
    /// decode cost and how much text one Backspace/Escape can lose.
    public var autoCommitSyllables: Int
    /// Candidate panel opens by itself while composing (more than one
    /// option). Off = it appears only once selection starts (Tab/Down/Up, the
    /// syllable cursor). The core default keeps the always-on behavior; the
    /// macOS preference defaults to off.
    public var autoShowCandidates: Bool
    /// Return while a candidate is being chosen (selection mode, focused
    /// word, symbol menu) only confirms it and leaves selection; the next
    /// Return commits. Off = Return commits everything at once. The core
    /// default is the commit-at-once behavior; the macOS preference defaults on.
    public var returnConfirmsSelection: Bool

    public init(fuzzyRepair: Bool = true, toneTolerance: Bool = true,
                candidateKeys: String = SelectionKeys.defaultKeys, userLearning: Bool = true,
                shiftToggle: Bool = true, jev: JevConfig = JevConfig(),
                autoCommitSyllables: Int = 24, autoShowCandidates: Bool = true,
                returnConfirmsSelection: Bool = false) {
        self.fuzzyRepair = fuzzyRepair
        self.toneTolerance = toneTolerance
        self.candidateKeys = candidateKeys
        self.userLearning = userLearning
        self.shiftToggle = shiftToggle
        self.jev = jev
        self.autoCommitSyllables = autoCommitSyllables
        self.autoShowCandidates = autoShowCandidates
        self.returnConfirmsSelection = returnConfirmsSelection
    }
}

/// Process-wide state shared by every `InputSession`: one IME process, one
/// keyboard, many clients (IMK controllers, fcitx5 input contexts). Not
/// thread-safe — touch it only from the thread that drives the sessions.
public final class InputEngine {
    public let decoder: LexiconDecoder
    /// Live preferences provider, called once per event.
    public var settings: () -> SessionSettings
    /// Diagnostic trace sink. Callers pass codes and counts, never text.
    public var log: (String) -> Void
    /// Explicit-opt-in user overlay, gated per keystroke by
    /// `SessionSettings.userLearning` — off means nil, i.e. byte-identical decode.
    public var userLexicon: UserLexicon
    /// Where learned words persist; nil = memory only (tests, replay).
    public var userLexiconURL: URL?
    /// Words the user added on purpose (and built-in words they hid): real
    /// trie entries in `decoder`, independent of `userLearning` — an explicit
    /// dictionary is not inference. Persisted at `userDictionaryURL`.
    public private(set) var userDictionary: UserDictionary
    public var userDictionaryURL: URL?
    private var userDictionaryStamp: Date?
    /// 中/英 mode: GLOBAL, not per-session — one physical keyboard, all
    /// clients. (Per-session state surprised users: toggling in one app
    /// never reached another.) Chinese on every launch.
    public var english = false
    /// Lone-Shift-tap state (single keyboard truth; reset on focus change).
    public var shiftTap = ShiftTapTracker()
    /// Recent committed sentences (in-memory only, never persisted): topic
    /// continuity for Jev runs across fields. Sent only under the same
    /// explicit Jev opt-in + key as user_context — same trust boundary, no
    /// wider. Capped small; trimming keeps one line per commit.
    public private(set) var recentCommits: [String] = []
    public static let recentCommitCap = 5
    public static let recentCommitChars = 48

    public init(decoder: LexiconDecoder,
                userLexicon: UserLexicon = UserLexicon(),
                userLexiconURL: URL? = nil,
                userDictionary: UserDictionary = UserDictionary(),
                userDictionaryURL: URL? = nil,
                settings: @escaping () -> SessionSettings = { SessionSettings() },
                log: @escaping (String) -> Void = { _ in }) {
        self.decoder = decoder
        self.userLexicon = userLexicon
        self.userLexiconURL = userLexiconURL
        self.userDictionary = userDictionary
        self.userDictionaryURL = userDictionaryURL
        self.settings = settings
        self.log = log
        decoder.applyUserDictionary(userDictionary)
        userDictionaryStamp = Self.modificationDate(userDictionaryURL)
    }

    // MARK: - User dictionary

    private static func modificationDate(_ url: URL?) -> Date? {
        guard let url else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Installs `dictionary` into the decoder and, when `persist`, writes it
    /// to `userDictionaryURL`. The Settings editor and the in-session
    /// "add phrase" gesture both land here.
    public func setUserDictionary(_ dictionary: UserDictionary, persist: Bool = true) {
        userDictionary = dictionary
        decoder.applyUserDictionary(dictionary)
        if persist, let url = userDictionaryURL { dictionary.save(to: url) }
        userDictionaryStamp = Self.modificationDate(userDictionaryURL)
        log("userdict words=\(dictionary.added.count) hidden=\(dictionary.excluded.count)")
    }

    /// Picks up edits made outside this process (a text editor, a sync tool).
    /// One `stat` — called when a composition starts, never per keystroke.
    public func reloadUserDictionaryIfChanged() {
        guard let url = userDictionaryURL else { return }
        let stamp = Self.modificationDate(url)
        guard stamp != userDictionaryStamp else { return }
        setUserDictionary(UserDictionary.load(from: url), persist: false)
    }

    func activeUserLexicon(_ settings: SessionSettings) -> UserLexicon? {
        settings.userLearning ? userLexicon : nil
    }

    func learn(_ words: [(key: String, text: String)]) {
        guard !words.isEmpty else { return }
        for word in words { userLexicon.record(key: word.key, text: word.text) }
        if let url = userLexiconURL { userLexicon.save(to: url) }
    }

    func recordCommit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentCommits.append(String(trimmed.prefix(Self.recentCommitChars)))
        if recentCommits.count > Self.recentCommitCap {
            recentCommits.removeFirst(recentCommits.count - Self.recentCommitCap)
        }
    }

    // MARK: - Jev acceptance grading

    /// Pending Jev evaluations awaiting their commit verdict (in-memory,
    /// capped): the gate only fires on untouched states (no pins/picks), so
    /// the eventually committed text for the SAME raw keys is the honest
    /// ground truth for that evaluation. Acceptance, not correctness — a
    /// user override after the fact still grades 0.
    struct JevVerdict {
        var rawKeys: String
        var pickedText: String
        var flip: Bool
        var confidence: Double
    }
    private var jevPending: [JevVerdict] = []
    static let jevPendingCap = 20

    func noteJevEval(rawKeys: String, pickedText: String, flip: Bool, confidence: Double) {
        jevPending.append(JevVerdict(rawKeys: rawKeys, pickedText: pickedText, flip: flip, confidence: confidence))
        if jevPending.count > Self.jevPendingCap {
            jevPending.removeFirst(jevPending.count - Self.jevPendingCap)
        }
    }

    /// Grade by exact raw-keys match (anything typed after the evaluation
    /// changes the keys, so only clean Return-commits of the evaluated state
    /// grade). Logs booleans only — never text (repo policy).
    func gradeJevEval(rawKeys: String, committed: String) {
        guard let index = jevPending.firstIndex(where: { $0.rawKeys == rawKeys }) else { return }
        let verdict = jevPending.remove(at: index)
        log("jev-grade accept=\(verdict.pickedText == committed ? 1 : 0) flip=\(verdict.flip ? 1 : 0) conf=\(String(format: "%.2f", verdict.confidence))")
    }

    /// Presence-only gate trace (never the key or text). Called on every
    /// decode entry point so remote intent stays observable per policy.
    func logJevGate(_ jev: JevConfig) {
        log("jev enabled=\(jev.enabled ? 1 : 0) rich=\(jev.allowRichContext ? 1 : 0) key=\(jev.hasKey ? 1 : 0)")
    }
}
