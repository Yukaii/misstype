import Cocoa
import MisstypeCore
import SwiftUI

/// Settings window: sidebar of panes, grouped forms on the right. Controls
/// bind straight to the `Misstype*` UserDefaults keys through @AppStorage —
/// the same store `MisstypePrefs` reads per keystroke — so a change applies
/// on the next key and `defaults write` shows up here live.
final class SettingsWindow: NSWindow {
    static let shared = SettingsWindow()

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = L("Misstype Settings")
        isReleasedWhenClosed = false
        contentMinSize = NSSize(width: 640, height: 440)
        contentViewController = NSHostingController(rootView: SettingsView())
        setContentSize(NSSize(width: 720, height: 640))
        setFrameAutosaveName("MisstypeSettingsWindow")
        if !setFrameUsingName("MisstypeSettingsWindow") { center() }
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
    }
}

private enum Pane: String, CaseIterable, Identifiable {
    case general, decoding, learning, dictionary, jev, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .decoding: return L("Decoding")
        case .learning: return L("Learning")
        case .dictionary: return L("My Dictionary")
        case .jev: return L("Jev Assist")
        case .about: return L("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "keyboard"
        case .decoding: return "wand.and.stars"
        case .learning: return "book.closed"
        case .dictionary: return "character.book.closed"
        case .jev: return "cloud"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @State private var pane: Pane = .general

    var body: some View {
        // Fixed two-column layout instead of NavigationSplitView: that adds
        // a translucent detail toolbar (a blank bar hiding the first section
        // header) and a sidebar-collapse button this window has no use for.
        HStack(spacing: 0) {
            List(Pane.allCases, selection: $pane) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            Group {
                switch pane {
                case .general: GeneralPane()
                case .decoding: DecodingPane()
                case .learning: LearningPane()
                case .dictionary: DictionaryPane()
                case .jev: JevPane()
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}

/// Toggle with a secondary explanation under the label.
private struct DescribedToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @AppStorage("MisstypeShiftToggle") private var shiftToggle = true
    @AppStorage("MisstypeAutoShowCandidates") private var autoShowCandidates = false
    @AppStorage("MisstypeReturnConfirmsSelection") private var returnConfirms = true
    @AppStorage("MisstypeMixedEnglish") private var mixedEnglish = false
    @AppStorage("MisstypeCandidateKeys") private var storedKeys = SelectionKeys.defaultKeys
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var labels: [String] {
        SelectionKeys.labels(keys: SelectionKeys.sanitize(draft))
    }

    var body: some View {
        Form {
            Section(L("Typing")) {
                DescribedToggle(
                    title: L("Tap Shift to switch Chinese/English"),
                    detail: L("Shift+Space always works. Turn this off if an app mishandles lone Shift presses."),
                    isOn: $shiftToggle)
                DescribedToggle(
                    title: L("Show candidates automatically"),
                    detail: L("Off: the candidate panel appears only after you press Tab or an arrow key."),
                    isOn: $autoShowCandidates)
                DescribedToggle(
                    title: L("Return confirms the selected candidate"),
                    detail: L("On: while choosing a candidate, Return only confirms it and a second Return sends the text. Off: Return sends the text immediately."),
                    isOn: $returnConfirms)
                DescribedToggle(
                    title: L("Recognize English words while typing"),
                    detail: L("Experimental. Keys that spell an English word (typos included) are offered as English without switching modes. Slower on long mixed sentences."),
                    isOn: $mixedEnglish)
            }
            Section(L("Selection keys")) {
                HStack {
                    TextField("", text: $draft)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 180)
                        .focused($editing)
                        .onSubmit(commit)
                    Button(L("Restore Default")) {
                        draft = SelectionKeys.defaultKeys
                        commit()
                    }
                    .disabled(SelectionKeys.sanitize(draft) == SelectionKeys.defaultKeys)
                }
                HStack(spacing: 6) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        VStack(spacing: 2) {
                            Text(label.uppercased())
                                .font(.system(.body, design: .monospaced).weight(.medium))
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                            Text("\(index + 1)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Text(L("Pick a candidate after pressing ↓ or Tab (or in the syllable cursor's list). Up to 8 keys; while typing they stay Zhuyin keys."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Candidate keys")) {
                shortcut("Tab · ↓", L("Next candidate"))
                shortcut("⇧Tab · ↑", L("Previous candidate"))
                shortcut("Page Down · =", L("Next page (= only while selecting)"))
                shortcut("Page Up · -", L("Previous page (- only while selecting)"))
                shortcut("← →", L("Move the syllable cursor"))
                shortcut("⏎", L("Commit"))
                shortcut("⇧⏎", L("Commit the keys as typed"))
                shortcut("Esc", L("Leave selection; press again to clear"))
            }
        }
        .onAppear { draft = storedKeys }
        .onChange(of: storedKeys) { newValue in if !editing { draft = newValue } }
        .onChange(of: editing) { isEditing in if !isEditing { commit() } }
    }

    private func commit() {
        let clean = SelectionKeys.sanitize(draft.trimmingCharacters(in: .whitespaces))
        storedKeys = clean
        draft = clean
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        LabeledContent {
            Text(keys).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
        } label: {
            Text(action)
        }
    }
}

// MARK: - Decoding

private struct DecodingPane: View {
    @AppStorage("MisstypeFuzzyRepair") private var fuzzy = true
    @AppStorage("MisstypeToneTolerance") private var tone = true

    var body: some View {
        Form {
            Section {
                DescribedToggle(
                    title: L("Fuzzy repair"),
                    detail: L("Recovers from transposed, substituted, missing or extra keys."),
                    isOn: $fuzzy)
                DescribedToggle(
                    title: L("Tone tolerance"),
                    detail: L("A wrong tone stays viable with a ranking penalty. Off: tones you type must match exactly; toneless input still works."),
                    isOn: $tone)
            } footer: {
                Text(L("Changes apply on the next keystroke. Decoding always runs offline."))
            }
        }
    }
}

// MARK: - Learning

private struct LearningPane: View {
    @AppStorage("MisstypeUserLearning") private var learning = true
    @State private var count = Runtime.engine.userLexicon.count
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                DescribedToggle(
                    title: L("Learn from explicit picks"),
                    detail: L("Remembers candidates you choose on purpose (Tab, arrows, selection keys, click) and ranks them higher next time. Stored only on this Mac."),
                    isOn: $learning)
                    .onChange(of: learning) { isOn in
                        if isOn { Runtime.engine.userLexicon = UserLexicon.load() }
                        count = Runtime.engine.userLexicon.count
                    }
            }
            Section(L("Learned phrases")) {
                LabeledContent(L("Entries"), value: "\(count)")
                HStack {
                    Button(L("Show in Finder")) {
                        Runtime.engine.userLexicon.save() // flush before revealing
                        NSWorkspace.shared.activateFileViewerSelecting([UserLexicon.defaultURL])
                    }
                    Button(L("Clear…"), role: .destructive) { confirmClear = true }
                        .disabled(count == 0)
                }
                Text(L("A portable local JSON file — copy it to export or back up."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { count = Runtime.engine.userLexicon.count }
        .alert(L("Clear all learned phrases?"), isPresented: $confirmClear) {
            Button(L("Clear"), role: .destructive) {
                Runtime.engine.userLexicon = UserLexicon()
                Runtime.engine.userLexicon.save()
                count = 0
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("This can't be undone."))
        }
    }
}

// MARK: - My dictionary

/// Plain-text editor over `user_dictionary.tsv` (the format is documented in
/// `UserDictionary`). Words are usually added from the keyboard — mark them
/// with Shift+←/→ and press Return — so this pane is for review, cleanup and
/// hand edits. Saving applies at once: the engine swaps the decoder overlay.
private struct DictionaryPane: View {
    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false
    @State private var importNote: String?

    private var parsed: (dictionary: UserDictionary, problems: [UserDictionary.Problem]) {
        UserDictionary.parse(text)
    }

    var body: some View {
        let result = parsed
        Form {
            Section {
                Text(L("Mark text while typing with Shift+← / → and press Return to add it here. Press Return on the same mark again to remove it."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("Import reads vChewing user data (.txt, UTF-8). To turn a plain word list into that format, use the online generator; it runs in your browser and uploads nothing."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(L("vChewing user data generator"), destination: URL(string: "https://vu.gh.miniasp.com/")!)
                Text(L("Third-party tool by Will 保哥 (MIT license), not affiliated with Misstype."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Words")) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    // Fixed height: with only a minimum the editor sizes to its
                    // text (a 1,600-line import made the pane thousands of pt tall);
                    // a bounded editor scrolls inside itself instead.
                    .frame(height: 280)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text(L("One word per line: the word, a space, then its Zhuyin readings joined by hyphens (vChewing user data format). Start a line with ! to hide a built-in word. # starts a comment."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let importNote {
                    Text(importNote).font(.caption).foregroundStyle(.secondary)
                }
                if !result.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(result.problems.prefix(5).enumerated()), id: \.offset) { _, problem in
                            Text(L("Line %d: %@", problem.line, problem.message))
                                .font(.caption).foregroundStyle(.red)
                        }
                        if result.problems.count > 5 {
                            Text(L("…and %d more", result.problems.count - 5))
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                HStack {
                    Text(L("%d words, %d hidden", result.dictionary.added.count, result.dictionary.excluded.count))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Import…")) { importFile() }
                    Button(L("Show in Finder")) {
                        if !FileManager.default.fileExists(atPath: UserDictionary.defaultURL.path) { save() }
                        NSWorkspace.shared.activateFileViewerSelecting([UserDictionary.defaultURL])
                    }
                    Button(L("Revert")) { load() }.disabled(text == saved)
                    Button(L("Save")) { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(text == saved)
                }
            }
        }
        .onAppear { if !loaded { load() } }
    }

    private func load() {
        let url = UserDictionary.defaultURL
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? Runtime.engine.userDictionary.serialized()
        saved = text
        loaded = true
    }

    /// Merges a picked file into the editor; the user reviews and presses Save.
    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            importNote = L("Could not read %@ as UTF-8 text.", url.lastPathComponent)
            return
        }
        let result = UserDictionary.importing(source, into: text)
        text = result.text
        importNote = L("Imported %d words (%d already there, %d lines skipped). Press Save to apply.",
                       result.added, result.duplicates, result.problems.count)
    }

    private func save() {
        guard UserDictionary.write(text: text, to: UserDictionary.defaultURL) else { NSSound.beep(); return }
        Runtime.engine.setUserDictionary(UserDictionary.parse(text).dictionary, persist: false)
        saved = text
        importNote = nil
    }
}

// MARK: - Jev

private struct JevPane: View {
    @AppStorage("MisstypeJevEnabled") private var enabled = false
    @AppStorage("MisstypeJevRichContext") private var rich = false
    @AppStorage("MisstypeJevApiKey") private var storedKey = ""
    @AppStorage("MisstypeJevModel") private var storedModel = JevConfig.defaultModel
    @State private var keyDraft = ""
    @State private var modelDraft = ""
    @State private var confirmEnable = false
    @FocusState private var focus: Field?
    private enum Field { case key, model }

    private var payload: String {
        L("Each evaluation sends: the Zhuyin keys, the candidate sentences, up to 60 characters before the cursor, your explicit picks, and the last 5 committed sentences. Don't use it in password fields.")
    }

    var body: some View {
        Form {
            Section {
                Text(L("Optional. When candidates are too close to call, a remote model can help decide. Off by default: Misstype decodes fully offline unless you enable this and provide a key."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("Enable Jev assistance"), isOn: Binding(
                    get: { enabled },
                    set: { if $0 { confirmEnable = true } else { enabled = false } }))
                Toggle(isOn: $rich) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Allow richer context"))
                        Text(L("Also sends alignment and diff metadata."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!enabled)
            }
            Section(L("Connection")) {
                LabeledContent(L("Gateway key")) {
                    SecureField(L("Never logged"), text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .key)
                        .onSubmit(commitKey)
                        .frame(maxWidth: 260)
                }
                LabeledContent(L("Model")) {
                    TextField("", text: $modelDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .model)
                        .onSubmit(commitModel)
                        .frame(maxWidth: 260)
                }
                Text(L("Or set the AI_GATEWAY_API_KEY environment variable."))
                    .font(.caption).foregroundStyle(.secondary)
                statusRow
            }
            Section(L("What is sent")) {
                Text(payload).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { keyDraft = storedKey; modelDraft = storedModel }
        .onChange(of: focus) { _ in commitKey(); commitModel() }
        .alert(L("Enable remote Jev assistance?"), isPresented: $confirmEnable) {
            Button(L("Enable")) { enabled = true }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Once enabled and a gateway key is present, candidate ties are sent to a remote model.") + "\n\n" + payload
                 + "\n\n" + L("Turning it off returns to offline decoding immediately."))
        }
    }

    private func commitKey() {
        let value = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        storedKey = value
        keyDraft = value
    }

    private func commitModel() {
        let value = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        storedModel = value.isEmpty ? JevConfig.defaultModel : value
        modelDraft = storedModel
    }

    /// Key presence only — never echoes the value.
    private var statusRow: some View {
        let config = MisstypePrefs.jevConfig
        let (color, text): (Color, String)
        if !config.enabled {
            (color, text) = (.secondary, L("Offline — the default"))
        } else if !config.hasKey {
            (color, text) = (.orange, L("Enabled, but no key — staying offline"))
        } else {
            (color, text) = (.green, L("Ready · %@ · %@", config.model,
                                       config.allowRichContext ? L("richer context") : L("minimal context")))
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout)
        }
    }
}

// MARK: - About

private struct UpdatesSection: View {
    @State private var automatic = UpdateController.shared.updater?.automaticallyChecksForUpdates ?? false

    var body: some View {
        Section(L("Updates")) {
            if let updater = UpdateController.shared.updater {
                Toggle(L("Check for updates automatically"), isOn: Binding(
                    get: { automatic },
                    set: { automatic = $0; updater.automaticallyChecksForUpdates = $0 }))
                Button(L("Check for Updates…")) { UpdateController.shared.checkForUpdates() }
                Text(L("Updates are fetched from GitHub. Only the app and macOS versions are sent, never what you type."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("This build was not set up for automatic updates."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return L("Version %@ (%@)", info?["CFBundleShortVersionString"] as? String ?? "?",
                 info?["CFBundleVersion"] as? String ?? "?")
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    if let icon = Bundle.main.image(forResource: "MisstypeIcon") {
                        Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Misstype")).font(.title2.weight(.semibold))
                        Text(L("Capture first, decode later.")).foregroundStyle(.secondary)
                        Text(version).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
            UpdatesSection()
            Section(L("Privacy")) {
                Text(L("What you type stays on this Mac. The decoder runs offline; nothing is sent anywhere unless you turn on Jev Assist."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Dictionaries")) {
                Text(L("McBopomofo and NAER public dictionary data. See THIRD_PARTY_NOTICES for licenses."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
