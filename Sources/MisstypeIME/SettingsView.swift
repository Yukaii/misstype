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
    case general, appearance, shortcuts, decoding, learning, dictionary, jev, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .appearance: return L("Appearance")
        case .shortcuts: return L("Shortcuts")
        case .decoding: return L("Decoding")
        case .learning: return L("Learning")
        case .dictionary: return L("My Dictionary")
        case .jev: return L("Jev Assist")
        case .about: return L("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .shortcuts: return "keyboard"
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
                case .appearance: AppearancePane()
                case .shortcuts: ShortcutsPane()
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
    @AppStorage("MisstypeAutoShowCandidates") private var autoShowCandidates = false
    @AppStorage("MisstypeReturnConfirmsSelection") private var returnConfirms = true
    @AppStorage("MisstypeMixedEnglish") private var mixedEnglish = false
    @AppStorage("MisstypeCursorCandidates") private var cursorCandidates = CursorCandidates.covering.rawValue

    var body: some View {
        Form {
            Section(L("Typing")) {
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
            Section(L("Syllable cursor")) {
                Picker(L("Candidates at the cursor"), selection: $cursorCandidates) {
                    Text(L("Every word covering the cursor")).tag(CursorCandidates.covering.rawValue)
                    Text(L("The word before the cursor (macOS Zhuyin)")).tag(CursorCandidates.endingAt.rawValue)
                    Text(L("The word after the cursor (Microsoft New Phonetic)")).tag(CursorCandidates.beginningAt.rawValue)
                }
                Text(L("Which words ← and → offer when you go back to fix one."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Appearance

/// Candidate panel look. Read by the panel on every redraw, so a change
/// shows at the next keystroke.
private struct AppearancePane: View {
    @AppStorage("MisstypePanelAppearance") private var appearance = PanelStyle.Appearance.system.rawValue
    @AppStorage("MisstypeCandidateFontSize") private var fontSize = PanelStyle.defaultFontSize
    @AppStorage("MisstypeAccentHighlight") private var accentHighlight = false
    @AppStorage("MisstypeCandidatesPerPage") private var perPage = SelectionKeys.defaultPageSize

    var body: some View {
        Form {
            Section(L("Candidate panel")) {
                Picker(L("Theme"), selection: $appearance) {
                    Text(L("Match System")).tag(PanelStyle.Appearance.system.rawValue)
                    Text(L("Light")).tag(PanelStyle.Appearance.light.rawValue)
                    Text(L("Dark")).tag(PanelStyle.Appearance.dark.rawValue)
                }
                LabeledContent(L("Font size")) {
                    HStack {
                        Slider(value: $fontSize, in: PanelStyle.fontSizes, step: 1)
                            .frame(maxWidth: 200)
                        Text(L("%d pt", Int(fontSize)))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Stepper(value: $perPage, in: SelectionKeys.pageSizes) {
                    LabeledContent(L("Candidates per page"), value: "\(perPage)")
                }
                DescribedToggle(
                    title: L("Highlight in the accent color"),
                    detail: L("Off: the selected row is a neutral gray."),
                    isOn: $accentHighlight)
            }
            Section(L("Preview")) {
                PanelPreview(fontSize: fontSize, accent: accentHighlight,
                             scheme: PanelStyle.Appearance(rawValue: appearance) ?? .system)
            }
        }
    }
}

/// A static sketch of the panel with the chosen style (not the real panel).
private struct PanelPreview: View {
    let fontSize: Double
    let accent: Bool
    let scheme: PanelStyle.Appearance
    private let rows = ["你好", "妳好", "擬好"]

    var body: some View {
        let preview = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, text in
                HStack(spacing: 8) {
                    Text(["a", "s", "d"][index])
                        .font(.system(size: fontSize - 2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(text).font(.system(size: fontSize))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(height: (fontSize * 28 / 15).rounded())
                .background(RoundedRectangle(cornerRadius: 6).fill(
                    index == 0 ? (accent ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.2))
                               : Color.clear))
            }
        }
        .padding(4)
        .frame(width: 180)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .shadow(radius: 3, y: 1)
        .padding(.vertical, 6)
        switch scheme {
        case .system: preview
        case .light: preview.environment(\.colorScheme, .light)
        case .dark: preview.environment(\.colorScheme, .dark)
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @AppStorage("MisstypeShiftToggle") private var shiftToggle = true
    @AppStorage("MisstypeShiftToggleSide") private var shiftSide = ShiftToggleSide.either.rawValue
    @AppStorage("MisstypeShiftSpaceToggle") private var shiftSpace = true
    @AppStorage("MisstypePageKeys") private var pageKeys = PageKeys.minusEqual.rawValue
    @AppStorage("MisstypeCandidatesPerPage") private var perPage = SelectionKeys.defaultPageSize
    @AppStorage("MisstypeCandidateKeys") private var storedKeys = SelectionKeys.defaultKeys
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var pageSize: Int { SelectionKeys.clampPageSize(perPage) }

    private var labels: [String] {
        SelectionKeys.labels(keys: SelectionKeys.sanitize(draft, pageSize: pageSize), pageSize: pageSize)
    }

    /// One picker over two stored keys: off, or which Shift taps.
    private var shiftChoice: Binding<String> {
        Binding(get: { shiftToggle ? shiftSide : "off" },
                set: { value in
                    shiftToggle = value != "off"
                    if value != "off" { shiftSide = value }
                })
    }

    private var paging: PageKeys { PageKeys(rawValue: pageKeys) ?? .minusEqual }

    var body: some View {
        Form {
            Section(L("Switch Chinese/English")) {
                Picker(L("Tap Shift"), selection: shiftChoice) {
                    Text(L("Either Shift")).tag(ShiftToggleSide.either.rawValue)
                    Text(L("Left Shift")).tag(ShiftToggleSide.left.rawValue)
                    Text(L("Right Shift")).tag(ShiftToggleSide.right.rawValue)
                    Text(L("Off")).tag("off")
                }
                Toggle(L("Shift+Space"), isOn: $shiftSpace)
                Text(shiftToggle || shiftSpace
                     ? L("Turn the Shift tap off if an app mishandles lone Shift presses.")
                     : L("With both off, no key switches between Chinese and English."))
                    .font(.caption).foregroundStyle(shiftToggle || shiftSpace ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .disabled(draft == SelectionKeys.defaultKeys)
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
                Text(L("Pick a candidate after pressing ↓ or Tab (or in the syllable cursor's list). One key per row of a page (%d now, see Appearance); while typing they stay Zhuyin keys.", pageSize))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Page keys")) {
                Picker(L("Turn pages while selecting"), selection: $pageKeys) {
                    Text("-  =").tag(PageKeys.minusEqual.rawValue)
                    Text(",  .").tag(PageKeys.commaPeriod.rawValue)
                    Text("[  ]").tag(PageKeys.brackets.rawValue)
                    Text(L("Page Up / Page Down only")).tag(PageKeys.none.rawValue)
                }
                Text(L("Page Up and Page Down always work. The extra keys type normally when you are not selecting; a key that is also a selection key picks instead."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Candidate keys")) {
                shortcut("Tab · ↓", L("Next candidate"))
                shortcut("⇧Tab · ↑", L("Previous candidate"))
                shortcut(paging.labels.map { "Page Down · \($0.next)" } ?? "Page Down", L("Next page"))
                shortcut(paging.labels.map { "Page Up · \($0.previous)" } ?? "Page Up", L("Previous page"))
                shortcut("← →", L("Move the syllable cursor"))
                shortcut("⇧← ⇧→", L("Mark a phrase for My Dictionary"))
                shortcut("⏎", L("Commit"))
                shortcut("⇧⏎", L("Commit the keys as typed"))
                shortcut("Esc", L("Leave selection; press again to clear"))
            }
        }
        .onAppear { draft = storedKeys }
        .onChange(of: storedKeys) { newValue in if !editing { draft = newValue } }
        .onChange(of: editing) { isEditing in if !isEditing { commit() } }
    }

    /// Stored up to the largest page so a later, larger page size keeps the
    /// keys; the session uses the first `pageSize` of them.
    private func commit() {
        let clean = SelectionKeys.sanitize(draft.trimmingCharacters(in: .whitespaces),
                                           pageSize: SelectionKeys.pageSizes.upperBound)
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
