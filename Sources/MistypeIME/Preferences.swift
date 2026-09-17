import Cocoa
import MistypeCore

/// User preferences: UserDefaults-backed, read live (no caching, so the
/// panel and `defaults write` take effect on the next keystroke).
/// - fuzzyRepair: tiered edit repair (transpose/neighbor/phonetic/insert/
///   delete). Off = exact + toneless readings only.
/// - toneTolerance: wrong-tone variants stay viable with a penalty. Off =
///   explicit tones must match exactly (toneless input still decodes via
///   toneless variants — strictness applies to asserted tones).
/// - candidateKeys: reserved for letter-row selection (roadmap item 3).
enum MistypePrefs {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "MistypeFuzzyRepair": true,
            "MistypeToneTolerance": true,
            "MistypeCandidateKeys": "asdfghjkl;",
            "MistypeUserLearning": true,
        ])
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
        get { UserDefaults.standard.string(forKey: "MistypeCandidateKeys") ?? "asdfghjkl;" }
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
}

/// Minimal preferences panel (utility window, no dock presence needed).
final class PreferencesPanel: NSPanel {
    static let shared = PreferencesPanel()

    private var fuzzyBox: NSButton!
    private var toneBox: NSButton!
    private var learnBox: NSButton!
    private var learnStatus: NSTextField!
    private var keysField: NSTextField!

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
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

        let keysLabel = NSTextField(labelWithString: "候選鍵 Candidate keys (reserved for letter-row selection):")
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
    }

    @objc private func fuzzyToggled(_ sender: NSButton) {
        MistypePrefs.fuzzyRepair = sender.state == .on
    }

    @objc private func toneToggled(_ sender: NSButton) {
        MistypePrefs.toneTolerance = sender.state == .on
    }

    @objc private func learnToggled(_ sender: NSButton) {
        MistypePrefs.userLearning = sender.state == .on
        if sender.state == .on {
            Runtime.userLexicon = UserLexicon.load()
        }
        refreshLearnStatus()
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

    @objc private func keysEdited(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespaces)
        MistypePrefs.candidateKeys = value.isEmpty ? "asdfghjkl;" : value
        sender.stringValue = MistypePrefs.candidateKeys
    }

    func show() {
        // Re-sync controls: defaults may change via `defaults write` too.
        fuzzyBox.state = MistypePrefs.fuzzyRepair ? .on : .off
        toneBox.state = MistypePrefs.toneTolerance ? .on : .off
        learnBox.state = MistypePrefs.userLearning ? .on : .off
        keysField.stringValue = MistypePrefs.candidateKeys
        refreshLearnStatus()
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
