import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

/// Preferences one keystroke is processed under. Adapters read them from
/// their own store (macOS: UserDefaults) — live, per event, never cached, so
/// a preference flip applies on the next keystroke.
public struct SessionSettings: Equatable, Sendable {
    /// How readily keyboard slips are repaired (`.off` = exact and toneless
    /// readings only).
    public var repairStrength: RepairStrength
    public var fuzzyRepair: Bool { repairStrength != .off }
    public var toneTolerance: Bool
    /// Selection keys (sanitized; see `SelectionKeys.sanitize`).
    public var candidateKeys: String
    public var userLearning: Bool
    /// Lone-Shift tap toggles 中/英 (Shift+Space always does).
    public var shiftToggle: Bool
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
    /// Bare keys that spell an English word (or a one-letter typo of one)
    /// are offered as English, and adopted when clearly better than the
    /// Chinese reading. Needs `english.tsv`; without it nothing changes.
    public var mixedEnglish: Bool
    /// Candidates per page (`SelectionKeys.pageSizes`, clamped): rows the
    /// host shows at once and how many selection keys address them.
    public var pageSize: Int {
        get { pageSizeValue }
        set { pageSizeValue = SelectionKeys.clampPageSize(newValue) }
    }
    private var pageSizeValue: Int
    /// User key bindings for IME actions (`KeyBindings`; default: the
    /// built-in keys, Shift+Space toggles 中/英).
    public var keyBindings: KeyBindings
    /// Which words the syllable cursor offers (default: all covering it).
    public var cursorCandidates: CursorCandidates
    /// Personal channel model: learn which keys this user swaps and cheapen
    /// exactly those repairs (`ChannelLearner`). Needs `userLearning` too.
    /// Off by default until measured on real typing.
    public var channelLearning: Bool

    public init(repairStrength: RepairStrength = .standard, toneTolerance: Bool = true,
                candidateKeys: String = SelectionKeys.defaultKeys, userLearning: Bool = true,
                shiftToggle: Bool = true,
                autoCommitSyllables: Int = 24, autoShowCandidates: Bool = true,
                returnConfirmsSelection: Bool = false, mixedEnglish: Bool = true,
                pageSize: Int = SelectionKeys.defaultPageSize,
                keyBindings: KeyBindings = KeyBindings(),
                cursorCandidates: CursorCandidates = .covering,
                channelLearning: Bool = false) {
        self.cursorCandidates = cursorCandidates
        self.channelLearning = channelLearning
        self.pageSizeValue = SelectionKeys.clampPageSize(pageSize)
        self.keyBindings = keyBindings
        self.repairStrength = repairStrength
        self.toneTolerance = toneTolerance
        self.candidateKeys = candidateKeys
        self.userLearning = userLearning
        self.shiftToggle = shiftToggle
        self.autoCommitSyllables = autoCommitSyllables
        self.autoShowCandidates = autoShowCandidates
        self.returnConfirmsSelection = returnConfirmsSelection
        self.mixedEnglish = mixedEnglish
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
    /// How this user mistypes (`SessionSettings.channelLearning`); applied
    /// to the decoder per refresh, nil when off.
    public var channelLearner = ChannelLearner()
    /// Where the channel model persists; nil = memory only.
    public var channelLearnerURL: URL?
    private let englishLock = NSLock()
    private var englishStore: EnglishLexicon?
    /// English word list for mixed typing (`english.tsv` beside the lexicon);
    /// nil until loaded or when the file is absent — then nothing changes.
    public var englishLexicon: EnglishLexicon? {
        get { englishLock.lock(); defer { englishLock.unlock() }; return englishStore }
        set { englishLock.lock(); englishStore = newValue; englishLock.unlock() }
    }

    /// Loads `english.tsv` from the lexicon directory. The index takes a few
    /// hundred ms to build, so by default it happens off the calling thread;
    /// keys typed before it finishes simply skip the English pass.
    public func loadEnglishLexicon(resourceDirectory: URL, background: Bool = true) {
        let url = resourceDirectory.appendingPathComponent("english.tsv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let build = { [weak self] in
            guard let tsv = try? String(contentsOf: url, encoding: .utf8) else { return }
            self?.englishLexicon = EnglishLexicon(tsv: tsv)
            self?.log("english words loaded")
        }
        #if canImport(Dispatch)
        if background { DispatchQueue.global(qos: .utility).async(execute: build) } else { build() }
        #else
        build()
        #endif
    }

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

    func activeChannel(_ settings: SessionSettings) -> ChannelModel? {
        settings.userLearning && settings.channelLearning ? channelLearner.model : nil
    }

    /// Forget every learned typo (settings "Clear"), on disk too.
    public func clearChannel() {
        channelLearner = ChannelLearner()
        if let url = channelLearnerURL { channelLearner.save(to: url) }
    }

    func observeChannel(_ evidence: ChannelEvidence) {
        guard !evidence.isEmpty else { return }
        channelLearner.observe(evidence)
        if let url = channelLearnerURL { channelLearner.save(to: url) }
    }

    func learn(_ words: [(key: String, text: String)]) {
        guard !words.isEmpty else { return }
        for word in words { userLexicon.record(key: word.key, text: word.text) }
        if let url = userLexiconURL { userLexicon.save(to: url) }
    }
}
