import Cocoa
@preconcurrency import Carbon
@preconcurrency import InputMethodKit
import MistypeCore

enum Runtime {
    static let decoder: LexiconDecoder = {
        guard let resources = Bundle.main.resourceURL,
              let decoder = LexiconLoader.load(resourceDirectory: resources, log: { NSLog("%@", $0) }) else {
            NSLog("Mistype: missing lexicon; refusing to start with a fixture decoder")
            exit(1)
        }
        return decoder
    }()
    /// Process-wide engine: every controller's session shares the decoder,
    /// the learned-phrase overlay, 中/英 mode and Shift-tap tracking.
    static let engine = InputEngine(decoder: decoder,
                                    userLexicon: UserLexicon.load(),
                                    userLexiconURL: UserLexicon.defaultURL,
                                    userDictionary: UserDictionary.load(),
                                    userDictionaryURL: UserDictionary.defaultURL,
                                    settings: { MistypePrefs.sessionSettings },
                                    log: debugLog)
    /// File trace for routing diagnosis (~/Library/Logs/MistypeIME-debug.log).
    /// NSLog is a black hole under TIS-launched ad-hoc builds, so diagnosis
    /// goes here instead. Codes and indices only — never text content.
    static func debugLog(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MistypeIME-debug.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attrs[.size] as? Int ?? 0) > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Transient 中/英 mode pill: flashes on every toggle (a blind toggle is
/// unusable). Borderless nonactivating panel like CandidatesPanel — never
/// steals focus; generation counter avoids hide-races on quick re-toggles.
final class ModeIndicator: NSPanel {
    static let shared = ModeIndicator()

    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 44, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none

        let body = NSView(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        body.wantsLayer = true
        body.layer?.cornerRadius = 11
        body.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView = body

        // NSTextField draws top-aligned in its frame — center the frame
        // itself vertically (metrics fixed once: 中/英 share fullwidth size).
        label.font = .systemFont(ofSize: 22)
        label.alignment = .center
        label.stringValue = "中"
        label.sizeToFit()
        label.frame = NSRect(x: 0, y: (44 - label.frame.height) / 2,
                             width: 44, height: label.frame.height)
        label.autoresizingMask = []
        body.addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - anchor: caret rect in screen coordinates (same source the
    ///   candidate panel uses). Same placement policy: above the caret,
    ///   flipping below only when clipped at the top; mouse fallback when
    ///   the client reports no caret (e.g. empty composition).
    func flash(english: Bool, anchor: NSRect?) {
        generation += 1
        let current = generation
        label.stringValue = english ? "英" : "中"
        let size = NSSize(width: 44, height: 44)
        if let anchor = anchor,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            var origin = NSPoint(x: anchor.minX, y: anchor.maxY + 6)
            if origin.y + size.height > visible.maxY { origin.y = anchor.minY - size.height - 6 }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
            setFrameOrigin(origin)
        } else {
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main {
                let visible = screen.visibleFrame
                var origin = NSPoint(x: mouse.x - 22, y: mouse.y + 12)
                origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
                origin.y = min(max(origin.y, visible.minY + size.height), visible.maxY)
                setFrameOrigin(origin)
            }
        }
        orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.generation == current else { return }
            self.orderOut(nil)
        }
    }
}

/// IMK adapter: translates NSEvents into `KeyEvent`s for its client's
/// `InputSession` and draws `session.view` (marked text + panel). Every
/// editing rule lives in the session; nothing here holds composition state.
@objc(MistypeInputController)
final class MistypeInputController: IMKInputController, InputSessionHost {
    private lazy var session: InputSession = {
        let session = InputSession(engine: Runtime.engine)
        session.host = self
        return session
    }()
    private weak var lastClient: IMKTextInput?
    /// What the client and panel show now; `render` pushes only differences.
    private var rendered = SessionView.empty
    private let missingRange = NSRange(location: NSNotFound, length: 0)

    /// Raw event inlet (vChewing parity): this controller deliberately does
    /// NOT implement `inputText:key:modifiers:client:` — when it does, the
    /// server takes the managed path and `handleEvent` never fires (verified
    /// 2026-09-18: mask queried fresh, inputText served, handleEvent dead).
    /// Without it, the server delivers raw NSEvents here for every masked
    /// type, and text is parsed exactly once. NSEvent shadow classes:
    /// never touch `.characters` on non-keyDown events (throws).
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        let phase: KeyEvent.Phase
        switch event.type {
        case .keyDown: phase = .press
        case .keyUp, .flagsChanged: phase = .release
        default: return false
        }
        lastClient = client
        activeController = self
        let keyCode = Int(event.keyCode)
        let result = session.handle(KeyEvent(MacKeyCode.key(keyCode), phase: phase,
                                             modifiers: Self.modifiers(event.modifierFlags),
                                             text: phase == .press ? event.characters : nil,
                                             nativeCode: keyCode))
        apply(result, client: client)
        return result.consumed
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyEvent.Modifiers {
        var out: KeyEvent.Modifiers = []
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.control) { out.insert(.control) }
        if flags.contains(.option) { out.insert(.option) }
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.capsLock) { out.insert(.capsLock) }
        return out
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue
            | NSEvent.EventTypeMask.flagsChanged.rawValue
            | NSEvent.EventTypeMask.keyUp.rawValue)
    }

    private func apply(_ result: KeyResult, client: IMKTextInput) {
        // Anchor BEFORE inserting: afterwards the marked text (and its caret
        // rect) is gone and the pill would fall back to the mouse.
        let anchor = result.modeChanged ? caretAnchor(client, length: rendered.preedit.utf16.count) : nil
        if let text = result.commit { insert(text, client) }
        render(client)
        if result.beep { NSSound.beep() }
        if result.modeChanged { ModeIndicator.shared.flash(english: Runtime.engine.english, anchor: anchor) }
    }

    /// Inserting replaces the marked text, so the client now shows none.
    private func insert(_ text: String, _ client: IMKTextInput) {
        client.insertText(text, replacementRange: missingRange)
        rendered.preedit = ""
        rendered.caret = 0
    }

    /// Push the session's view (single owner of the highlight — the panel
    /// never calls back except for clicks, so no echo loop is possible).
    private func render(_ client: IMKTextInput) {
        let view = session.view
        guard view != rendered else { return }
        if view.showsCandidates {
            candidatePanel.update(candidates: view.candidates,
                                  selected: view.selected,
                                  keyLabels: view.selectionKeys,
                                  keysActive: view.keysActive,
                                  anchor: caretAnchor(client, length: view.preedit.utf16.count),
                                  mark: view.mark)
        } else {
            candidatePanel.hidePanel()
        }
        if view.preedit != rendered.preedit || view.caret != rendered.caret || view.mark != rendered.mark {
            // Focused mode parks the caret at the start of the focused word;
            // end mode keeps it after the last unit (converted or pending raw).
            // A phrase mark is the marked text's selection, which clients
            // draw highlighted.
            let selection = view.mark.map { NSRange(location: $0.range.lowerBound, length: $0.range.count) }
                ?? NSRange(location: view.caret, length: 0)
            client.setMarkedText(view.preedit, selectionRange: selection,
                                 replacementRange: missingRange)
        }
        rendered = view
    }

    /// Caret rect in screen coordinates for panel placement (McBopomofo-style:
    /// walk back from the end of marked text until a non-zero line height
    /// rect comes back). Logs the outcome class (numbers only): 1 = client
    /// reports only zero rects, 2 = positioned.
    private func caretAnchor(_ client: IMKTextInput, length: Int) -> NSRect? {
        var rect = NSRect(x: 0, y: 0, width: 16, height: 16)
        var cursor = length
        if cursor > 0 { cursor -= 1 }
        while rect.origin.x == 0, rect.origin.y == 0, cursor >= 0 {
            _ = client.attributes(forCharacterIndex: cursor, lineHeightRectangle: &rect)
            cursor -= 1
        }
        guard rect.origin.x != 0 || rect.origin.y != 0 else {
            Runtime.debugLog("anchor=1")
            return nil
        }
        Runtime.debugLog("anchor=2")
        return rect
    }

    /// Panel click routing (the panel is global, controllers are per-client).
    func pickCandidate(at index: Int) {
        session.pick(at: index)
        if let client = lastClient { render(client) }
    }

    // MARK: - InputSessionHost

    /// Safely extracts preceding text context and bundle identifier from the client.
    func surroundingContext() -> ClientContext {
        guard let client = lastClient else { return ClientContext() }
        return SurroundingContext.extract(from: IMKTextInputContextAdapter(client))
    }

    func perform(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    func sessionDidChange(_ session: InputSession) {
        if let client = lastClient { render(client) }
    }

    // MARK: - IMK lifecycle

    override func menu() -> NSMenu! {
        Runtime.debugLog("[ime] menu() requested")
        let menu = NSMenu(title: "Mistype")
        menu.autoenablesItems = false
        // Persistent mode readout (the flash pill is transient): which
        // language bare keys will produce right now.
        let mode = NSMenuItem(title: Runtime.engine.english ? L("English mode") : L("Chinese mode"),
                              action: nil, keyEquivalent: "")
        mode.state = .on
        mode.isEnabled = false
        menu.addItem(mode)
        let prefs = NSMenuItem(title: L("Settings…"), action: #selector(openPreferences(_:)), keyEquivalent: "")
        prefs.target = nil
        prefs.isEnabled = true
        menu.addItem(prefs)
        return menu
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        return true
    }

    @objc func openPreferences(_ sender: Any?) {
        Runtime.debugLog("[ime] openPreferences called")
        DispatchQueue.main.async {
            SettingsWindow.shared.show()
        }
    }

    override func originalString(_ sender: Any!) -> NSAttributedString { NSAttributedString(string: session.rawPhonetic) }
    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        if let text = session.commit() { insert(text, client) }
        render(client)
    }
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        activeController = self
        if let client = sender as? IMKTextInput {
            lastClient = client
        }
        session.resetModifierState()
        Runtime.debugLog("[ime] activateServer")
    }

    override func deactivateServer(_ sender: Any!) {
        Runtime.debugLog("[ime] deactivateServer")
        session.resetModifierState()
        commitComposition(sender)
        super.deactivateServer(sender)
    }
}

// --session-trace <keys> [--auto-commit N]: the full InputSession (real
// lexicon, no user lexicon) key by key. Prints per-key latency, every
// auto-commit chunk, and the final text (dev measurement, offline).
if let traceIndex = CommandLine.arguments.firstIndex(of: "--session-trace"),
   traceIndex + 1 < CommandLine.arguments.count {
    MistypePrefs.register()
    final class TraceHost: InputSessionHost {
        func surroundingContext() -> ClientContext { ClientContext() }
        func perform(_ work: @escaping () -> Void) { work() }
        func sessionDidChange(_ session: InputSession) {}
    }
    var settings = MistypePrefs.sessionSettings
    if let flag = CommandLine.arguments.firstIndex(of: "--auto-commit"),
       flag + 1 < CommandLine.arguments.count, let value = Int(CommandLine.arguments[flag + 1]) {
        settings.autoCommitSyllables = value
    }
    let engine = InputEngine(decoder: Runtime.decoder, settings: { settings })
    let session = InputSession(engine: engine)
    let host = TraceHost()
    session.host = host
    var committed = ""
    for (count, char) in CommandLine.arguments[traceIndex + 1].enumerated() {
        let label = String(char)
        let event = label == " " ? KeyEvent(.space, text: " ") : KeyEvent(.character(label), text: label)
        let started = Date()
        let result = session.handle(event)
        let ms = Date().timeIntervalSince(started) * 1000
        print("time\t\(count + 1)\t\(String(format: "%.1f", ms))")
        if let text = result.commit {
            committed += text
            print("chunk\t\(count + 1)\t\(text)\tpreedit=\(session.view.preedit)")
        }
    }
    let rest = session.handle(KeyEvent(.enter, text: "\r")).commit ?? ""
    print("final\t\(committed + rest)")
    exit(0)
}

if let decodeIndex = CommandLine.arguments.firstIndex(of: "--decode"),
   decodeIndex + 1 < CommandLine.arguments.count {
    // Measurement fidelity: the decode CLI must see the same registered
    // defaults as a live launch (fuzzyRepair/toneTolerance/userLearning all
    // default true). register() normally runs at the bottom next to app.run(),
    // which this early-exit path never reaches — every --decode number ever
    // measured ran the no-fuzzy, no-tolerance baseline instead.
    MistypePrefs.register()
    func compose<S: Sequence>(_ keys: S) -> Composition where S.Element == Character {
    var composition = Composition()
    var latin = false
    for key in keys {
        let label = String(key)
        if label == "`" {
            latin.toggle()
            continue
        }
        if label == " " {
            if !composition.isEmpty { _ = composition.appendSpace() }
            continue
        }
        if latin, label.count == 1, let char = label.first,
           char.isASCII, char.isLetter {
            _ = composition.appendLatin(label)
            continue
        }
        // Uppercase ASCII mirrors Shift+letter (inline latin, no commit).
        if !latin, label.count == 1, let char = label.first,
           char.isASCII, char.isUppercase {
            _ = composition.appendLatin(label)
            continue
        }
        latin = false
        if Punctuation.literals.contains(label) {
            _ = composition.appendLiteral(label)
        } else if !composition.append(label) {
            _ = composition.retoneLast(label)
        }
    }
    return composition
    }
    let keyText = CommandLine.arguments[decodeIndex + 1]
    let composition = compose(keyText)
    // --live-trace: the IME preview after every keystroke (tools/live_trace.py).
    if CommandLine.arguments.contains("--live-trace") {
        let decoder = Runtime.decoder
        let keys = Array(keyText)
        // --settle K: auto-settle words K+ syllables before the end (and
        // earlier runs), carried across keystrokes as the IME does.
        var keep: Int?
        if let settleIndex = CommandLine.arguments.firstIndex(of: "--settle"),
           settleIndex + 1 < CommandLine.arguments.count { keep = Int(CommandLine.arguments[settleIndex + 1]) }
        var settled = UserLexicon()
        for count in 1...max(keys.count, 1) where count <= keys.count {
            let keyStarted = Date()
            let preview = decoder.livePreview(compose(keys.prefix(count)), fuzzy: MistypePrefs.fuzzyRepair,
                                              toneTolerance: MistypePrefs.toneTolerance,
                                              settled: keep == nil || settled.isEmpty ? nil : settled)
            let keyMs = Date().timeIntervalSince(keyStarted) * 1000
            print("live\t\(count)\t\(preview.text())")
            print("time\t\(count)\t\(String(format: "%.1f", keyMs))")
            if let keep, let top = preview.candidates.first { settled = UserLexicon.settled(from: top, keep: keep) }
        }
        exit(0)
    }
    let started = Date()
    let decoder = Runtime.decoder
    let loaded = Date()
    let parsed = composition.parsed
    var userLexicon: UserLexicon?
    if let flagIndex = CommandLine.arguments.firstIndex(of: "--user-lexicon"),
       flagIndex + 1 < CommandLine.arguments.count {
        userLexicon = UserLexicon.load(from: URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1]))
    }
    let results = decoder.decodeSegments(composition.segments, pendingKeys: parsed.pending, fuzzy: MistypePrefs.fuzzyRepair, toneTolerance: MistypePrefs.toneTolerance, userLexicon: userLexicon, locked: decodeLocks())
    let jevGate = MistypePrefs.jevConfig
    print("entries=\(decoder.entryCount) user=\(userLexicon?.count ?? 0) load_ms=\(loaded.timeIntervalSince(started) * 1000) decode_ms=\(Date().timeIntervalSince(loaded) * 1000) jev_enabled=\(jevGate.enabled ? 1 : 0) jev_key=\(jevGate.hasKey ? 1 : 0) jev_rich=\(jevGate.allowRichContext ? 1 : 0)")
    for candidate in results {
        var line = "\(candidate.text)\t\(candidate.score)\trepairs=\(candidate.repairs) unresolved=\(candidate.unresolved)"
        if CommandLine.arguments.contains("--align") {
            line += "\talign=" + candidate.alignment.map {
                "\($0.syllables.lowerBound)-\($0.syllables.upperBound):\($0.chars.lowerBound)-\($0.chars.upperBound)"
            }.joined(separator: ",")
        }
        print(line)
    }
    if let segIndex = CommandLine.arguments.firstIndex(of: "--segment"),
       segIndex + 1 < CommandLine.arguments.count {
        let bounds = CommandLine.arguments[segIndex + 1].split(separator: ":").compactMap { Int($0) }
        if bounds.count == 2 {
            let syllables = composition.syllables(finishing: true)
            let queryStart = Date()
            let options = decoder.segmentOptions(syllables, span: bounds[0]..<bounds[1])
            print("segment \(bounds[0]):\(bounds[1]) query_ms=\(Date().timeIntervalSince(queryStart) * 1000)")
            for option in options.prefix(8) { print("  \(option.text)\t\(option.score)") }
        }
    }
    // --replay <expected>: cursor-pick count per candidate model (tools/cursor_replay.py).
    if let replayIndex = CommandLine.arguments.firstIndex(of: "--replay"),
       replayIndex + 1 < CommandLine.arguments.count {
        for model in [CursorReplay.Model.aligned, .startAtCursor] {
            let live = Array(parsed.pending.prefix(decoder.livePendingCut(
                parsed.pending, toneTolerance: MistypePrefs.toneTolerance)))
            let outcome = CursorReplay.run(decoder, segments: composition.segments, pendingKeys: live,
                                           expected: CommandLine.arguments[replayIndex + 1], model: model,
                                           fuzzy: MistypePrefs.fuzzyRepair, toneTolerance: MistypePrefs.toneTolerance,
                                           userLexicon: userLexicon)
            print("replay \(model.rawValue) picks=\(outcome.picks.map(String.init) ?? "-") ranks=\(outcome.ranks.map(String.init).joined(separator: ",")) learned=\(outcome.learned.joined(separator: ","))")
            // --learn-out <path>: commit the covering-model outcome's words
            // into a (synthetic) lexicon file, as the IME would on Return.
            if model == .startAtCursor, let outIndex = CommandLine.arguments.firstIndex(of: "--learn-out"),
               outIndex + 1 < CommandLine.arguments.count, !outcome.learned.isEmpty {
                let url = URL(fileURLWithPath: CommandLine.arguments[outIndex + 1])
                var learned = UserLexicon.load(from: url)
                for pair in outcome.learned {
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2 { learned.record(key: parts[0], text: parts[1], at: Date(timeIntervalSince1970: 0)) }
                }
                learned.save(to: url)
            }
        }
    }
    exit(0)
}

/// --lock key=text (repeatable): session pins for falsifying segment locks.
/// Key is the toneless-concatenated span (see UserLexicon).
private func decodeLocks() -> UserLexicon? {
    var pins = UserLexicon()
    var found = false
    for argument in CommandLine.arguments.dropFirst() {
        guard argument.hasPrefix("--lock=") else { continue }
        let pair = argument.dropFirst("--lock=".count).split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { continue }
        pins.entries[pair[0], default: [:]][pair[1]] = UserLexicon.Record(count: 1, updatedAt: 0)
        found = true
    }
    return found ? pins : nil
}

ProcessInfo.processInfo.disableAutomaticTermination("MistypeIME Input Method")
ProcessInfo.processInfo.disableSuddenTermination()

let app = NSApplication.shared
_ = Runtime.decoder
let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String ?? "org.mistype.inputmethod.Mistype_Connection"
guard NSClassFromString("MistypeInputController") != nil,
      let bundleID = Bundle.main.bundleIdentifier,
      let server = IMKServer(name: connectionName, bundleIdentifier: bundleID) else {
    NSLog("Mistype: InputMethodKit initialization failed for \(connectionName)")
    exit(1)
}
/// Active controller for panel click routing (controllers are per-client).
weak var activeController: MistypeInputController?
var candidatePanel = CandidatesPanel(onPick: { index in
    activeController?.pickCandidate(at: index)
})
extension NSApplication {
    @objc func openPreferences(_ sender: Any?) {
        Runtime.debugLog("[ime] NSApp openPreferences called")
        DispatchQueue.main.async {
            SettingsWindow.shared.show()
        }
    }
}

MistypePrefs.register()
// Retained: DistributedNotificationCenter returns an opaque token that must
// stay alive, otherwise the observer is released immediately and the
// cross-process preferences trigger silently never fires.
var prefsObserver: NSObjectProtocol?
prefsObserver = DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("org.mistype.openPreferences"),
    object: nil,
    queue: .main
) { _ in
    Runtime.debugLog("[ime] notification openPreferences received")
    SettingsWindow.shared.show()
}
if CommandLine.arguments.contains("--preferences") {
    SettingsWindow.shared.show()
}
withExtendedLifetime((server, candidatePanel)) { app.run() }
