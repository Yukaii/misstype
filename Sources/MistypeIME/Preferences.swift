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
        ])
    }

    /// Lone-Shift-tap toggles 中/英 (default on; Shift+Space always works).
    /// Kill-switch for clients that misdeliver modifier events.
    static var shiftToggle: Bool {
        get { UserDefaults.standard.bool(forKey: "MistypeShiftToggle") }
        set { UserDefaults.standard.set(newValue, forKey: "MistypeShiftToggle") }
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

/// Minimal preferences panel (utility window, no dock presence needed).
final class PreferencesPanel: NSPanel {
    static let shared = PreferencesPanel()

    private var fuzzyBox: NSButton!
    private var toneBox: NSButton!
    private var learnBox: NSButton!
    private var learnStatus: NSTextField!
    private var keysField: NSTextField!
    private var shiftBox: NSButton!
    private var jevBox: NSButton!
    private var richBox: NSButton!
    private var keyField: NSSecureTextField!
    private var modelField: NSTextField!
    private var jevStatus: NSTextField!

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 580),
                   styleMask: [.titled, .closable, .utilityWindow],
                   backing: .buffered, defer: false)
        title = "Mistype Preferences"
        isFloatingPanel = true
        level = .popUpMenu

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView!.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView!.bottomAnchor),
        ])

        let fuzzy = NSButton(checkboxWithTitle: "模糊修復 Fuzzy repair (transpose/substitute/insert/delete)",
                             target: self, action: #selector(fuzzyToggled(_:)))
        fuzzy.state = MistypePrefs.fuzzyRepair ? .on : .off
        fuzzyBox = fuzzy
        stack.addArrangedSubview(fuzzy)

        let tone = NSButton(checkboxWithTitle: "聲調容錯 Tone tolerance (wrong tones recoverable)",
                            target: self, action: #selector(toneToggled(_:)))
        tone.state = MistypePrefs.toneTolerance ? .on : .off
        toneBox = tone
        stack.addArrangedSubview(tone)

        let learn = NSButton(checkboxWithTitle: "記住明確選擇 Learn from explicit picks (local only)",
                             target: self, action: #selector(learnToggled(_:)))
        learn.state = MistypePrefs.userLearning ? .on : .off
        learnBox = learn
        stack.addArrangedSubview(learn)

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        learnStatus = status
        stack.addArrangedSubview(status)

        let learnRow = NSStackView()
        learnRow.orientation = .horizontal
        learnRow.spacing = 8
        let reveal = NSButton(title: "Reveal phrases file", target: self, action: #selector(revealPhrases(_:)))
        reveal.bezelStyle = .rounded
        learnRow.addArrangedSubview(reveal)
        let clear = NSButton(title: "Clear learned phrases", target: self, action: #selector(clearPhrases(_:)))
        clear.bezelStyle = .rounded
        learnRow.addArrangedSubview(clear)
        stack.addArrangedSubview(learnRow)

        let keysLabel = NSTextField(labelWithString: "選字鍵 Selection keys (after ↓ / Tab / ←; up to 8):")
        keysLabel.font = .systemFont(ofSize: 12)
        keysLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(keysLabel)

        let keys = NSTextField(string: MistypePrefs.candidateKeys)
        keys.target = self
        keys.action = #selector(keysEdited(_:))
        keysField = keys
        stack.addArrangedSubview(keys)

        let note = NSTextField(labelWithString: "Takes effect on the next keystroke. See docs/project-outline.md M5.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(note)

        let shift = NSButton(checkboxWithTitle: "單敲 Shift 切換中英 Tap Shift toggles Chinese/English",
                             target: self, action: #selector(shiftToggled(_:)))
        shift.state = MistypePrefs.shiftToggle ? .on : .off
        shiftBox = shift
        stack.addArrangedSubview(shift)

        let jevTitle = NSTextField(labelWithString: "Jev gateway (explicit opt-in, offline by default):")
        jevTitle.font = .systemFont(ofSize: 12)
        jevTitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(jevTitle)

        let jev = NSButton(checkboxWithTitle: "啟用 Jev 協助 Enable Jev assistance (needs key below)",
                           target: self, action: #selector(jevToggled(_:)))
        jev.state = MistypePrefs.jevEnabled ? .on : .off
        jevBox = jev
        stack.addArrangedSubview(jev)

        // Always-visible egress disclosure: what leaves the device per
        // evaluation, when, and the password caution. The checkbox alone
        // ("needs key") never said any of this — informed consent needs the
        // payload list where the switch is.
        let disclosure = NSTextField(wrappingLabelWithString:
            "開啟後、候選糾結時，每次評估會傳送：注音按鍵、候選句、游標前最多 60 字、你的親選用字、最近 5 句已提交文字。預設關閉；請勿在密碼欄使用。")
        disclosure.font = .systemFont(ofSize: 11)
        disclosure.textColor = .tertiaryLabelColor
        disclosure.preferredMaxLayoutWidth = 328
        stack.addArrangedSubview(disclosure)

        let rich = NSButton(checkboxWithTitle: "允許豐富上下文 Allow richer context (alignment/diff/contract)",
                            target: self, action: #selector(richToggled(_:)))
        rich.state = MistypePrefs.jevRichContext ? .on : .off
        richBox = rich
        stack.addArrangedSubview(rich)

        let keyLabel = NSTextField(labelWithString: "Gateway key (never logged; or set AI_GATEWAY_API_KEY env):")
        keyLabel.font = .systemFont(ofSize: 12)
        keyLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(keyLabel)

        let key = NSSecureTextField(string: MistypePrefs.jevApiKey)
        key.target = self
        key.action = #selector(keyEdited(_:))
        keyField = key
        stack.addArrangedSubview(key)

        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.font = .systemFont(ofSize: 12)
        modelLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(modelLabel)

        let model = NSTextField(string: MistypePrefs.jevModel)
        model.target = self
        model.action = #selector(modelEdited(_:))
        modelField = model
        stack.addArrangedSubview(model)

        let jevStatusField = NSTextField(wrappingLabelWithString: "")
        jevStatusField.font = .systemFont(ofSize: 12)
        jevStatusField.textColor = .secondaryLabelColor
        jevStatusField.preferredMaxLayoutWidth = 328
        jevStatus = jevStatusField
        stack.addArrangedSubview(jevStatusField)
    }

    @objc private func fuzzyToggled(_ sender: NSButton) {
        MistypePrefs.fuzzyRepair = sender.state == .on
    }

    @objc private func toneToggled(_ sender: NSButton) {
        MistypePrefs.toneTolerance = sender.state == .on
    }

    @objc private func shiftToggled(_ sender: NSButton) {
        MistypePrefs.shiftToggle = sender.state == .on
    }

    @objc private func learnToggled(_ sender: NSButton) {
        MistypePrefs.userLearning = sender.state == .on
        if sender.state == .on {
            Runtime.userLexicon = UserLexicon.load()
        }
        refreshLearnStatus()
    }

    @objc private func jevToggled(_ sender: NSButton) {        // Explicit consent at the moment of enabling: flipping this switch
        // starts sending text to a remote model (once a key is present), so
        // an accidental click must not silently arm it. Turning off is
        // immediate and needs no confirmation.
        if sender.state == .on {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "啟用 Jev 遠端協助？"
            alert.informativeText =
                "開啟後、候選糾結時，每次評估會傳送：注音按鍵、候選句、游標前最多 60 字、你的親選用字、最近 5 句已提交文字。只有提供 gateway key 後才會真正傳送；關閉即回到離線解碼。請勿在密碼欄使用。"
            alert.addButton(withTitle: "啟用 Enable")
            alert.addButton(withTitle: "取消 Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                sender.state = .off
                MistypePrefs.jevEnabled = false
                refreshJevStatus()
                return
            }
        }
        MistypePrefs.jevEnabled = sender.state == .on
        refreshJevStatus()
    }

    @objc private func richToggled(_ sender: NSButton) {
        MistypePrefs.jevRichContext = sender.state == .on
        refreshJevStatus()
    }

    @objc private func keyEdited(_ sender: NSSecureTextField) {
        MistypePrefs.jevApiKey = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        sender.stringValue = MistypePrefs.jevApiKey
        refreshJevStatus()
    }

    @objc private func modelEdited(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        MistypePrefs.jevModel = value.isEmpty ? JevConfig.defaultModel : value
        sender.stringValue = MistypePrefs.jevModel
        refreshJevStatus()
    }

    @objc private func revealPhrases(_ sender: NSButton) {
        Runtime.userLexicon.save() // flush before revealing
        NSWorkspace.shared.activateFileViewerSelecting([UserLexicon.defaultURL])
    }

    @objc private func clearPhrases(_ sender: NSButton) {
        Runtime.userLexicon = UserLexicon()
        Runtime.userLexicon.save()
        refreshLearnStatus()
    }

    private func refreshLearnStatus() {
        learnStatus.stringValue =
            "Learned phrases: \(Runtime.userLexicon.count) (local JSON, portable — copy it to export)"
    }

    /// Key presence only — never echoes the value.
    private func refreshJevStatus() {
        let config = MistypePrefs.jevConfig
        if !config.enabled {
            jevStatus.stringValue = "Jev: offline (default — enable + key to assist)"
        } else if !config.hasKey {
            jevStatus.stringValue = "Jev: enabled but no key — staying offline"
        } else {
            jevStatus.stringValue = "Jev: ready (\(config.model))"
                + (config.allowRichContext ? " + richer context" : " (minimal context)")
                + " — sends the listed text on each tied pick"
        }
    }

    @objc private func keysEdited(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespaces)
        MistypePrefs.candidateKeys = SelectionKeys.sanitize(value)
        sender.stringValue = MistypePrefs.candidateKeys
    }

    func show() {
        // Re-sync controls: defaults may change via `defaults write` too.
        fuzzyBox.state = MistypePrefs.fuzzyRepair ? .on : .off
        toneBox.state = MistypePrefs.toneTolerance ? .on : .off
        learnBox.state = MistypePrefs.userLearning ? .on : .off
        shiftBox.state = MistypePrefs.shiftToggle ? .on : .off
        keysField.stringValue = MistypePrefs.candidateKeys
        refreshLearnStatus()
        jevBox.state = MistypePrefs.jevEnabled ? .on : .off
        richBox.state = MistypePrefs.jevRichContext ? .on : .off
        keyField.stringValue = MistypePrefs.jevApiKey
        modelField.stringValue = MistypePrefs.jevModel
        refreshJevStatus()
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
