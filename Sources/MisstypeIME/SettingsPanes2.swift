import Cocoa
import MisstypeMacKit
import MisstypeZigBridge

// MARK: - Learning

final class LearningPane: SettingsPane, NSTableViewDataSource, NSTableViewDelegate {
    private var phrases: [ZigEngine.LearnedPhrase] = []
    private var shown: [ZigEngine.LearnedPhrase] = []
    private var slips: [ZigEngine.ChannelPair] = []
    private let table = NSTableView()
    private let search = NSSearchField()
    private let emptyNote = UI.label("", color: .secondaryLabelColor)
    private let entries = UI.label("", color: .secondaryLabelColor)
    private var clearPhrases: NSButton?

    override func build() {
        let learning = switchControl(key: "MisstypeUserLearning")
        learning.onAction { [weak self] in
            UserDefaults.standard.set(learning.state == .on, forKey: "MisstypeUserLearning")
            if learning.state == .on { Runtime.zigEngine.reloadLearnedPhrases() }
            self?.reloadData()
        }
        group(rows: [
            row(L("Learn from explicit picks"),
                detail: L("Remembers candidates you choose on purpose (Tab, arrows, selection keys, click) and ranks them higher next time. Stored only on this Mac."),
                control: learning),
        ])

        // Learned phrases: count, search, table, actions.
        search.placeholderString = L("Search")
        search.onTextChange { [weak self] in self?.applyFilter() }
        search.onAction { [weak self] in self?.applyFilter() }

        table.tableColumns.forEach(table.removeTableColumn)
        let phraseColumn = NSTableColumn(identifier: .init("phrase"))
        phraseColumn.title = ""
        phraseColumn.width = 120
        let readingColumn = NSTableColumn(identifier: .init("readings"))
        readingColumn.width = 200
        let countColumn = NSTableColumn(identifier: .init("count"))
        countColumn.width = 40
        let forgetColumn = NSTableColumn(identifier: .init("forget"))
        forgetColumn.width = 28
        for column in [phraseColumn, readingColumn, countColumn, forgetColumn] { table.addTableColumn(column) }
        table.headerView = nil
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        let finder = UI.button(L("Show in Finder")) {
            Runtime.zigEngine.saveLearnedPhrases() // flush before revealing
            NSWorkspace.shared.activateFileViewerSelecting([UserFiles.learnedPhrases])
        }
        let clear = UI.button(L("Clear…")) { [weak self] in self?.confirmClearPhrases() }
        clear.contentTintColor = .systemRed
        clearPhrases = clear
        let content = UI.vstack([
            UI.hstack([entries, NSView()]),
            search, scroll, emptyNote,
            UI.hstack([finder, clear]),
        ], spacing: 8)
        for view in [search, scroll] { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        group(L("Learned phrases"), footer: L("A portable local JSON file — copy it to export or back up."),
              rows: [block(content: content)])

        // Typing slips.
        group(rows: [
            row(L("Learn my typing slips (experimental)"),
                detail: L("Notices keys you often swap, such as ㄥ typed for ㄣ, from Backspace re-types and the candidates you pick, and corrects exactly those more readily. Adapts slowly, forgets habits you drop, and backs off when you undo a correction. Stores keys and counts only, on this Mac."),
                control: switchControl(key: "MisstypeChannelLearning")),
        ])
        var slipRows: [NSView] = []
        if slips.isEmpty {
            slipRows.append(block(content: UI.label(L("None yet"), color: .secondaryLabelColor)))
        } else {
            for slip in slips {
                let percent = Int((exp(-slip.cost) * 100).rounded())
                slipRows.append(row(slip.typed + " → " + slip.intended,
                                    control: UI.label(L("about %d%% of the time", percent), color: .secondaryLabelColor)))
            }
        }
        let clearSlips = UI.button(L("Clear…")) { [weak self] in self?.confirmClearSlips() }
        clearSlips.isEnabled = !slips.isEmpty
        clearSlips.contentTintColor = .systemRed
        slipRows.append(block(content: UI.hstack([clearSlips, NSView()])))
        group(L("Learned typing slips"), rows: slipRows)
    }

    override func paneWillShow() {
        reloadData()
    }

    /// Re-reads engine state; rebuilds only the slips group when it changed.
    private func reloadData() {
        phrases = Runtime.zigEngine.learnedPhrases
        let nextSlips = Runtime.zigEngine.channelPairs
        let slipsChanged = nextSlips != slips
        slips = nextSlips
        applyFilter()
        if slipsChanged { reload() }
    }

    private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = query.isEmpty ? phrases : phrases.filter { $0.text.contains(query) || $0.readings.contains(query) }
        entries.stringValue = L("Entries") + ": \(phrases.count)"
        emptyNote.stringValue = shown.isEmpty ? (phrases.isEmpty ? L("None yet") : L("No matches")) : ""
        clearPhrases?.isEnabled = !phrases.isEmpty
        table.reloadData()
    }

    private func confirmClearPhrases() {
        let alert = NSAlert()
        alert.messageText = L("Clear all learned phrases?")
        alert.informativeText = L("This can't be undone.")
        alert.addButton(withTitle: L("Clear")).hasDestructiveAction = true
        alert.addButton(withTitle: L("Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Runtime.zigEngine.clearLearnedPhrases()
            self?.reloadData()
        }
    }

    private func confirmClearSlips() {
        let alert = NSAlert()
        alert.messageText = L("Clear all learned typing slips?")
        alert.informativeText = L("This can't be undone.")
        alert.addButton(withTitle: L("Clear")).hasDestructiveAction = true
        alert.addButton(withTitle: L("Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Runtime.zigEngine.clearChannel()
            self?.reloadData()
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shown.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let phrase = shown[row]
        switch id {
        case "phrase": return UI.label(phrase.text)
        case "readings":
            return UI.label(phrase.readings.replacingOccurrences(of: "|", with: " → "),
                            size: NSFont.smallSystemFontSize, color: .secondaryLabelColor)
        case "count":
            return UI.label("×\(phrase.count)", size: NSFont.smallSystemFontSize, color: .tertiaryLabelColor)
        default:
            let button = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: L("Forget this phrase")) ?? NSImage(),
                                  target: nil, action: nil)
            button.isBordered = false
            button.toolTip = L("Forget this phrase")
            button.onAction { [weak self] in
                Runtime.zigEngine.forgetLearnedPhrase(phrase)
                self?.reloadData()
            }
            return button
        }
    }
}

// MARK: - My dictionary

/// Plain-text editor over `user_dictionary.tsv` (the format is documented in
/// `UserDictionary`). Words are usually added from the keyboard — mark them
/// with Shift+←/→ and press Return — so this pane is for review, cleanup and
/// hand edits. Saving applies at once: the engine swaps the decoder overlay.
final class DictionaryPane: SettingsPane, NSTextViewDelegate {
    private var textView: NSTextView!
    private var saved = ""
    private var loaded = false
    private let problems = UI.label("", size: NSFont.smallSystemFontSize, color: .systemRed)
    private let count = UI.label("", size: NSFont.smallSystemFontSize, color: .secondaryLabelColor)
    private let importNote = UI.caption("", width: SettingsPane.contentWidth - 28)
    private let revert = NSButton()
    private let save = NSButton()

    override func build() {
        let intro = UI.vstack([
            UI.caption(L("Mark text while typing with Shift+← / → and press Return to add it here. Press Return on the same mark again to remove it."),
                       width: SettingsPane.contentWidth - 28),
            UI.caption(L("Import reads vChewing user data (.txt, UTF-8). To turn a plain word list into that format, use the online generator; it runs in your browser and uploads nothing."),
                       width: SettingsPane.contentWidth - 28),
            generatorLink(),
            UI.caption(L("Third-party tool by Will 保哥 (MIT license), not affiliated with Misstype."),
                       width: SettingsPane.contentWidth - 28),
        ], spacing: 6)
        group(rows: [block(content: intro)])

        // Fixed-height editor: a bounded text view scrolls inside itself.
        let scroll = NSTextView.scrollableTextView()
        scroll.heightAnchor.constraint(equalToConstant: 280).isActive = true
        scroll.borderType = .lineBorder
        textView = scroll.documentView as? NSTextView
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.delegate = self

        revert.title = L("Revert")
        revert.bezelStyle = .rounded
        revert.onAction { [weak self] in self?.load() }
        save.title = L("Save")
        save.bezelStyle = .rounded
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        save.onAction { [weak self] in self?.saveText() }
        let importButton = UI.button(L("Import…")) { [weak self] in self?.importFile() }
        let export = UI.button(L("Export…")) { [weak self] in self?.exportFile() }
        let finder = UI.button(L("Show in Finder")) { [weak self] in
            if !FileManager.default.fileExists(atPath: UserFiles.userDictionary.path) { self?.saveText() }
            NSWorkspace.shared.activateFileViewerSelecting([UserFiles.userDictionary])
        }
        let editor = UI.vstack([
            scroll,
            UI.caption(L("One word per line: the word, a space, then its Zhuyin readings joined by hyphens (vChewing user data format). Start a line with ! to hide a built-in word. # starts a comment."),
                       width: SettingsPane.contentWidth - 28),
            importNote, problems,
            UI.hstack([count, NSView(), importButton, export, finder, revert, save]),
        ], spacing: 8)
        for view in editor.arrangedSubviews { view.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true }
        group(L("Words"), rows: [block(content: editor)])

        if !loaded { load() } else { textView.string = pendingText; check() }
    }

    private var pendingText = ""

    private func generatorLink() -> NSTextField {
        let link = NSTextField(labelWithAttributedString: NSAttributedString(
            string: L("vChewing user data generator"),
            attributes: [.link: URL(string: "https://vu.gh.miniasp.com/")!,
                         .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]))
        link.allowsEditingTextAttributes = true
        link.isSelectable = true
        return link
    }

    func textDidChange(_ notification: Notification) {
        pendingText = textView.string
        check()
    }

    private func check() {
        let result = ZigEngine.checkUserDictionary(textView.string)
        var lines = result.problems.prefix(5).map { L("Line %d: %@", $0.line, $0.message) }
        if result.problems.count > 5 { lines.append(L("…and %d more", result.problems.count - 5)) }
        problems.stringValue = lines.joined(separator: "\n")
        problems.isHidden = lines.isEmpty
        count.stringValue = L("%d words, %d hidden", result.added, result.hidden)
        let changed = textView.string != saved
        revert.isEnabled = changed
        save.isEnabled = changed
    }

    private func load() {
        let text = (try? String(contentsOf: UserFiles.userDictionary, encoding: .utf8)) ?? Runtime.zigEngine.userDictionaryText
        textView.string = text
        pendingText = text
        saved = text
        loaded = true
        check()
    }

    /// Merges a picked file into the editor; the user reviews and presses Save.
    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            importNote.stringValue = L("Could not read %@ as UTF-8 text.", url.lastPathComponent)
            return
        }
        let result = ZigEngine.importUserDictionary(source, into: textView.string)
        textView.string = result.text
        pendingText = result.text
        importNote.stringValue = L("Imported %d words (%d already there, %d lines skipped). Press Save to apply.",
                                   result.added, result.duplicates, result.skipped)
        check()
    }

    /// Writes the editor's current text (saved or not) where the user picks.
    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "misstype-user-dictionary.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !UserFiles.write(textView.string, to: url) { NSSound.beep() }
    }

    private func saveText() {
        guard UserFiles.write(textView.string, to: UserFiles.userDictionary) else { NSSound.beep(); return }
        Runtime.zigEngine.reloadUserDictionary()
        saved = textView.string
        importNote.stringValue = ""
        check()
    }
}

// MARK: - About

final class AboutPane: SettingsPane {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return L("Version %@ (%@)", info?["CFBundleShortVersionString"] as? String ?? "?",
                 info?["CFBundleVersion"] as? String ?? "?")
    }

    override func build() {
        var header: [NSView] = []
        if let icon = Bundle.main.image(forResource: "MisstypeIcon") {
            let image = NSImageView(image: icon)
            image.widthAnchor.constraint(equalToConstant: 72).isActive = true
            image.heightAnchor.constraint(equalToConstant: 72).isActive = true
            header.append(image)
        }
        header.append(UI.vstack([
            UI.label(L("Misstype"), size: 26, weight: .bold),
            UI.label(L("Capture first, decode later."), color: .secondaryLabelColor),
            UI.label(version, size: NSFont.smallSystemFontSize, color: .tertiaryLabelColor),
        ], spacing: 4))
        group(rows: [block(content: UI.hstack(header, spacing: 16))])

        // Updates.
        var updateRows: [NSView]
        if let updater = UpdateController.shared.updater {
            let automatic = NSSwitch()
            automatic.state = updater.automaticallyChecksForUpdates ? .on : .off
            automatic.onAction { updater.automaticallyChecksForUpdates = automatic.state == .on }
            updateRows = [
                row(L("Check for updates automatically"), control: automatic),
                row(L("Check for Updates…"), control: UI.button(L("Check for Updates…")) {
                    UpdateController.shared.checkForUpdates()
                }),
                block(content: UI.caption(L("Updates are fetched from GitHub. Only the app and macOS versions are sent, never what you type."),
                                          width: SettingsPane.contentWidth - 28)),
            ]
        } else {
            updateRows = [block(content: UI.caption(L("This build was not set up for automatic updates."),
                                                    width: SettingsPane.contentWidth - 28))]
        }
        group(L("Updates"), rows: updateRows)
        group(L("Privacy"), rows: [block(content: UI.caption(
            L("What you type stays on this Mac. The decoder runs offline and never sends your typing anywhere."),
            width: SettingsPane.contentWidth - 28))])
        group(L("Dictionaries"), rows: [block(content: UI.caption(
            L("McBopomofo and NAER public dictionary data. See THIRD_PARTY_NOTICES for licenses."),
            width: SettingsPane.contentWidth - 28))])
    }
}
