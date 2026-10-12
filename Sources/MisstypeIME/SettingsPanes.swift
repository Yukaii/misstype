import Cocoa
import MisstypeMacKit

// MARK: - General

final class GeneralPane: SettingsPane {
    override func build() {
        group(L("Language"), rows: [
            row(L("Interface language"), control: popup(
                key: UILanguage.userDefaultsKey,
                options: [(L("Match System"), "")] + UILanguage.choices.map { ($0.name, $0.code) })),
        ])
        group(L("Typing"), rows: [
            toggleRow(L("Show candidates automatically"),
                      detail: L("Off: the candidate panel appears only after you press Tab or an arrow key."),
                      key: "MisstypeAutoShowCandidates"),
            toggleRow(L("Return confirms the selected candidate"),
                      detail: L("On: while choosing a candidate, Return only confirms it and a second Return sends the text. Off: Return sends the text immediately."),
                      key: "MisstypeReturnConfirmsSelection"),
            toggleRow(L("Recognize English words while typing"),
                      detail: L("Experimental. Keys that spell an English word (typos included) are offered as English without switching modes. Slower on long mixed sentences."),
                      key: "MisstypeMixedEnglish"),
        ])
        group(L("Syllable cursor"), rows: [
            row(L("Candidates at the cursor"),
                detail: L("Which words ← and → offer when you go back to fix one."),
                control: popup(key: "MisstypeCursorCandidates", options: [
                    (L("Every word covering the cursor"), CursorCandidates.covering.rawValue),
                    (L("The word before the cursor (macOS Zhuyin)"), CursorCandidates.endingAt.rawValue),
                    (L("The word after the cursor (Microsoft New Phonetic)"), CursorCandidates.beginningAt.rawValue),
                ])),
        ])
    }
}

// MARK: - Appearance

final class AppearancePane: SettingsPane {
    private let dots = ThemeDotsView()
    private let themeName = UI.label("", color: .secondaryLabelColor)
    private let sketch = PanelSketchView()

    private var theme: PanelTheme {
        PanelTheme(rawValue: UserDefaults.standard.string(forKey: "MisstypePanelTheme") ?? "") ?? .system
    }

    override func build() {
        let choose = UI.button(L("Choose…")) { [weak self] in
            guard let self else { return }
            self.presentAsSheet(ThemeStudioController())
        }
        let schemeRow = row(L("Color scheme"), control: UI.hstack([dots, themeName, choose], spacing: 10))

        let appearance = segmented(key: "MisstypePanelAppearance", options: [
            (L("Match System"), PanelStyle.Appearance.system.rawValue),
            (L("Light"), PanelStyle.Appearance.light.rawValue),
            (L("Dark"), PanelStyle.Appearance.dark.rawValue),
        ])
        let fontSize = sliderControl(
            key: "MisstypeCandidateFontSize", range: PanelStyle.fontSizes,
            format: { L("%d pt", Int($0)) },
            read: { PanelStyle.clampFontSize(UserDefaults.standard.double(forKey: "MisstypeCandidateFontSize")) })
        let radius = sliderControl(
            key: "MisstypePanelCornerRadius", range: PanelStyle.cornerRadii,
            format: { L("%d pt", Int($0)) },
            read: { PanelStyle.clampCornerRadius(UserDefaults.standard.double(forKey: "MisstypePanelCornerRadius")) })
        let families = NSFontManager.shared.availableFontFamilies
        let fontOptions = { (system: String) in [(system, "")] + families.map { ($0, $0) } }

        // Candidates per page: stepper with its value beside it.
        let perPage = UI.label("", color: .secondaryLabelColor)
        perPage.alignment = .right
        perPage.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let stepper = NSStepper()
        stepper.minValue = Double(SelectionKeys.pageSizes.lowerBound)
        stepper.maxValue = Double(SelectionKeys.pageSizes.upperBound)
        stepper.increment = 1
        stepper.onAction { MisstypePrefs.candidatesPerPage = Int(stepper.doubleValue) }
        onRefresh {
            let value = MisstypePrefs.candidatesPerPage
            stepper.integerValue = value
            perPage.stringValue = "\(value)"
        }

        group(L("Candidate panel"), rows: [
            toggleRow(L("Show all pages side by side"),
                      detail: L("Up to 4 pages in columns. ↑ ↓ move through every candidate and Tab turns pages; ← → stay the syllable cursor."),
                      key: "MisstypeCandidateGrid"),
            schemeRow,
            row(L("Light or dark"), control: appearance),
            row(L("Font size"), control: fontSize),
            row(L("Candidate font"), control: popup(key: "MisstypeCandidateFontFamily",
                                                    options: fontOptions(L("System")), separatorAfter: 0)),
            row(L("Selection key font"), control: popup(key: "MisstypeCandidateKeyFontFamily",
                                                        options: fontOptions(L("System Monospaced")), separatorAfter: 0)),
            row(L("Corner radius"), control: radius),
            row(L("Candidates per page"), control: UI.hstack([perPage, stepper], spacing: 4)),
        ])

        sketch.width = 180
        let holder = NSView()
        sketch.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(sketch)
        NSLayoutConstraint.activate([
            sketch.topAnchor.constraint(equalTo: holder.topAnchor, constant: 4),
            sketch.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -4),
            sketch.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
        ])
        group(L("Preview"), rows: [block(content: holder)])

        onRefresh { [weak self] in
            guard let self else { return }
            let scheme = PanelStyle.Appearance(rawValue: UserDefaults.standard.string(forKey: "MisstypePanelAppearance") ?? "") ?? .system
            let force: Bool? = scheme == .system ? nil : scheme == .dark
            let dark = force ?? (self.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            let palette = self.theme.palette(dark: dark)
            self.dots.forceDarkAppearance(force)
            self.dots.palette = palette
            self.themeName.stringValue = self.theme.title
            self.sketch.forceDark = force
            self.sketch.style = MisstypePrefs.panelStyle
            self.sketch.palette = palette
        }
    }
}

private extension NSView {
    func forceDarkAppearance(_ dark: Bool?) {
        appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
    }
}

// MARK: - Shortcuts

final class ShortcutsPane: SettingsPane {
    private var recordingAction: KeyAction?
    private let recorder = ChordRecorder()
    private var lastBindings = ""

    private var bindings: KeyBindings {
        KeyBindings.parse(UserDefaults.standard.string(forKey: "MisstypeKeyBindings") ?? "")
    }

    private var pageSize: Int {
        SelectionKeys.clampPageSize(UserDefaults.standard.integer(forKey: "MisstypeCandidatesPerPage"))
    }

    override func build() {
        let currentBindings = bindings
        lastBindings = currentBindings.serialized

        // Switch Chinese/English: toggle plus a note that turns orange when
        // nothing can switch.
        let note = UI.caption("", width: SettingsPane.contentWidth - 28)
        onRefresh { [weak self] in
            guard let self else { return }
            let canSwitch = UserDefaults.standard.bool(forKey: "MisstypeShiftToggle")
                || !self.bindings.chords(for: .toggleEnglish).isEmpty
            note.stringValue = canSwitch
                ? L("Turn the Shift tap off if an app mishandles lone Shift presses. Shift+Space also switches; change it under Key bindings.")
                : L("With the Shift tap off and no binding for it, no key switches between Chinese and English.")
            note.textColor = canSwitch ? .secondaryLabelColor : .systemOrange
            // Rebuild when another writer (defaults write) changed the bindings.
            if self.bindings.serialized != self.lastBindings { DispatchQueue.main.async { self.reload() } }
        }
        group(L("Switch Chinese/English"), rows: [
            toggleRow(L("Tap Shift to switch Chinese/English"), key: "MisstypeShiftToggle"),
            block(content: note),
        ])

        group(L("Selection keys"), rows: [selectionKeysBlock()])

        let restore = UI.button(L("Restore Defaults")) { [weak self] in
            UserDefaults.standard.set("", forKey: "MisstypeKeyBindings")
            self?.reload()
        }
        restore.isEnabled = !currentBindings.overrides.isEmpty
        group(L("Key bindings"), headerAccessory: restore,
              footer: L("Click + and press a key combination. Letters, digits and symbols need ⌃, ⌥ or ⌘, since alone they type Zhuyin. A removed default key goes to the app instead."),
              rows: KeyAction.allCases.map { bindingRow($0, currentBindings) })
    }

    override func paneWillShow() {
        // Leaving the pane mid-recording must not leave a key monitor behind.
        recorder.stop()
        recordingAction = nil
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        recorder.stop()
    }

    // MARK: Selection keys

    private func selectionKeysBlock() -> NSView {
        let field = NSTextField(string: "")
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let caps = NSStackView()
        caps.orientation = .horizontal
        caps.spacing = 6

        func commit() {
            // Stored up to the largest page so a later, larger page size
            // keeps the keys; the session uses the first `pageSize` of them.
            let clean = SelectionKeys.sanitize(field.stringValue.trimmingCharacters(in: .whitespaces),
                                               pageSize: SelectionKeys.pageSizes.upperBound)
            UserDefaults.standard.set(clean, forKey: "MisstypeCandidateKeys")
            field.stringValue = clean
        }
        field.onAction(commit)
        let restore = UI.button(L("Restore Default")) {
            field.stringValue = SelectionKeys.defaultKeys
            commit()
        }
        onRefresh { [weak self] in
            guard let self else { return }
            let stored = UserDefaults.standard.string(forKey: "MisstypeCandidateKeys") ?? SelectionKeys.defaultKeys
            if field.currentEditor() == nil { field.stringValue = stored }
            restore.isEnabled = stored != SelectionKeys.defaultKeys
            let size = self.pageSize
            let labels = SelectionKeys.labels(keys: SelectionKeys.sanitize(stored, pageSize: size), pageSize: size)
            caps.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (index, label) in labels.enumerated() {
                let cap = UI.label(label.uppercased(), weight: .medium)
                cap.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
                cap.alignment = .center
                cap.wantsLayer = true
                cap.layer?.cornerRadius = 6
                cap.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
                cap.widthAnchor.constraint(equalToConstant: 28).isActive = true
                cap.heightAnchor.constraint(equalToConstant: 28).isActive = true
                let number = UI.label("\(index + 1)", size: 10, color: .tertiaryLabelColor)
                let column = UI.vstack([cap, number], spacing: 2)
                column.alignment = .centerX
                caps.addArrangedSubview(column)
            }
        }
        let note = UI.caption(L("Pick a candidate after pressing ↓ or Tab (or in the syllable cursor's list). One key per row of a page (%d now, see Appearance); while typing they stay Zhuyin keys.", pageSize),
                              width: SettingsPane.contentWidth - 28)
        return block(content: UI.vstack([UI.hstack([field, restore]), caps, note], spacing: 10))
    }

    // MARK: Key bindings

    private func bindingRow(_ action: KeyAction, _ current: KeyBindings) -> NSView {
        let chords = current.chords(for: action)
        let conflicts = current.conflicts
        var items: [NSView] = []
        for chord in chords {
            let chip = NSButton(title: chord.symbol + "  ✕", target: nil, action: nil)
            chip.bezelStyle = .inline
            chip.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            chip.toolTip = conflicts.contains(chord) ? L("Also bound to another action") : nil
            if conflicts.contains(chord) { chip.contentTintColor = .systemOrange }
            chip.onAction { [weak self] in self?.set(action, chords.filter { $0 != chord }) }
            items.append(chip)
        }
        if chords.isEmpty { items.append(UI.label(L("None"), color: .tertiaryLabelColor)) }
        let recording = recordingAction == action
        let add = UI.button(recording ? L("Press keys…") : "+", role: .rounded) { [weak self] in
            guard let self else { return }
            if recording {
                self.recorder.stop()
                self.recordingAction = nil
                self.reload()
            } else {
                self.recordingAction = action
                self.recorder.start { chord in
                    self.recordingAction = nil
                    if !chords.contains(chord) { self.set(action, chords + [chord]) } else { self.reload() }
                }
                self.reload()
            }
        }
        add.controlSize = .small
        items.append(add)
        if current.overrides[action] != nil {
            let reset = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: L("Restore Default")) ?? NSImage(),
                                 target: nil, action: nil)
            reset.bezelStyle = .inline
            reset.isBordered = false
            reset.toolTip = L("Restore Default")
            reset.onAction { [weak self] in
                var next = self?.bindings ?? KeyBindings()
                next.overrides[action] = nil
                UserDefaults.standard.set(next.serialized, forKey: "MisstypeKeyBindings")
                self?.reload()
            }
            items.append(reset)
        }
        return row(action.title, control: UI.hstack(items, spacing: 4))
    }

    private func set(_ action: KeyAction, _ chords: [KeyChord]) {
        var next = bindings
        next.overrides[action] = chords == action.defaultChords ? nil : chords
        UserDefaults.standard.set(next.serialized, forKey: "MisstypeKeyBindings")
        reload()
    }
}

/// Captures the next key-down in this app's windows (the Settings window)
/// and swallows it, so recording never types into a field.
final class ChordRecorder {
    private var monitor: Any?

    func start(_ record: @escaping (KeyChord) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let chord = KeyChord(event: event) else {
                NSSound.beep()
                return nil
            }
            self?.stop()
            record(chord)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}

// MARK: - Decoding

final class DecodingPane: SettingsPane {
    override func build() {
        group(footer: L("Changes apply on the next keystroke. Decoding always runs offline."), rows: [
            row(L("Fuzzy repair"),
                detail: L("Recovers from transposed, substituted, missing or extra keys. Gentle suits precise typists: what you type wins unless it makes no sense. Strong suits frequent slips: a wrong key that still spells a real syllable is also fixed when the fix completes a word. Slower on long input without tones."),
                control: popup(key: "MisstypeRepairStrength", options: [
                    (L("Off"), RepairStrength.off.rawValue),
                    (L("Gentle"), RepairStrength.light.rawValue),
                    (L("Standard"), RepairStrength.standard.rawValue),
                    (L("Strong"), RepairStrength.strong.rawValue),
                ])),
            toggleRow(L("Tone tolerance"),
                      detail: L("A wrong tone stays viable with a ranking penalty. Off: tones you type must match exactly; toneless input still works."),
                      key: "MisstypeToneTolerance"),
        ])
    }
}
