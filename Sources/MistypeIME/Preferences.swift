import Cocoa

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
}

/// Minimal preferences panel (utility window, no dock presence needed).
final class PreferencesPanel: NSPanel {
    static let shared = PreferencesPanel()

    private var fuzzyBox: NSButton!
    private var toneBox: NSButton!
    private var keysField: NSTextField!

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 210),
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

    @objc private func keysEdited(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespaces)
        MistypePrefs.candidateKeys = value.isEmpty ? "asdfghjkl;" : value
        sender.stringValue = MistypePrefs.candidateKeys
    }

    func show() {
        // Re-sync controls: defaults may change via `defaults write` too.
        fuzzyBox.state = MistypePrefs.fuzzyRepair ? .on : .off
        toneBox.state = MistypePrefs.toneTolerance ? .on : .off
        keysField.stringValue = MistypePrefs.candidateKeys
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
