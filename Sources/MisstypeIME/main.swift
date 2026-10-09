import Cocoa
@preconcurrency import Carbon
@preconcurrency import InputMethodKit
import MisstypeMacKit
import MisstypeZigBridge

enum Runtime {
    /// Process-wide engine: every controller's session shares the lexicon,
    /// the learned-phrase overlay, 中/英 mode and Shift-tap tracking. User
    /// data lives in the platform default paths (the sandbox container).
    static let zigEngine: ZigEngine = {
        guard let resources = Bundle.main.resourceURL,
              let engine = ZigEngine(resourceDirectory: resources, userLexiconPath: nil) else {
            NSLog("Misstype: missing lexicon or Zig engine unavailable; refusing to start")
            exit(1)
        }
        // misstype_engine_new keeps the dictionary and channel in memory only.
        engine.setUserDictionaryPath(nil)
        engine.setChannelPath(nil)
        return engine
    }()
    /// File trace for routing diagnosis (~/Library/Logs/MisstypeIME-debug.log).
    /// NSLog is a black hole under TIS-launched ad-hoc builds, so diagnosis
    /// goes here instead. Codes and indices only — never text content.
    static func debugLog(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MisstypeIME-debug.log")
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
@objc(MisstypeInputController)
final class MisstypeInputController: IMKInputController {
    private lazy var session: ZigSessionAdapter = {
        guard let session = ZigSessionAdapter(engine: Runtime.zigEngine) else {
            NSLog("Misstype: failed to create Zig session")
            exit(1)
        }
        return session
    }()
    private weak var lastClient: IMKTextInput?
    /// What the client and panel show now; `render` pushes only differences.
    private var rendered = SessionView.empty
    private let missingRange = NSRange(location: NSNotFound, length: 0)
    /// The composition is drawn in the floating window (client cannot show it).
    private var popupActive = false
    /// Bundle ID of the focused client, cached from live calls (handle,
    /// activateServer) so menu() never has to query a possibly dead client.
    private var clientBundleID: String?

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
        if clientBundleID == nil { clientBundleID = client.bundleIdentifier() }
        activeController = self
        UpdateController.noteKey(composing: !rendered.preedit.isEmpty)
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
        let anchor = result.modeChanged || result.latinToggled ? caretAnchor(client, length: rendered.preedit.utf16.count) : nil
        if let text = result.commit { insert(text, client) }
        render(client)
        if result.beep { NSSound.beep() }
        if result.latinToggled { ModeIndicator.shared.flash(english: session.latinActive, anchor: anchor) }
        if result.modeChanged { ModeIndicator.shared.flash(english: Runtime.zigEngine.isEnglish, anchor: anchor) }
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
                                  pageSize: view.pageSize,
                                  style: MisstypePrefs.panelStyle,
                                  anchor: caretAnchor(client, length: view.preedit.utf16.count),
                                  mark: view.mark)
        } else {
            candidatePanel.hidePanel()
        }
        if view.preedit != rendered.preedit || view.caret != rendered.caret || view.mark != rendered.mark
            || view.segments != rendered.segments || view.focus != rendered.focus {
            // Focused mode parks the caret at the start of the focused word;
            // end mode keeps it after the last unit (converted or pending raw).
            // A phrase mark is the marked text's selection, which clients
            // draw highlighted.
            let selection = view.mark.map { NSRange(location: $0.range.lowerBound, length: $0.range.count) }
                ?? NSRange(location: view.caret, length: 0)
            // Styled marked text, as McBopomofo/vChewing send it: with a bare
            // String some clients treat the text as plain and never draw the
            // caret or the selection inside it, which is what the removed
            // self-drawn "|" header was papering over.
            let popup = !view.preedit.isEmpty && ClientMitigation.needsPopup(bundleID: client.bundleIdentifier())
            // Clients that cannot show marked text get a one-space
            // placeholder (the composition stays alive for IMK) and the
            // real text in a floating window.
            let marked = popup
                ? NSAttributedString(string: " ", attributes: [
                    .underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0])
                : Self.markedText(view)
            client.setMarkedText(marked, selectionRange: popup ? NSRange(location: 0, length: 0) : selection,
                                 replacementRange: missingRange)
            popupActive = popup
        }
        if popupActive, !view.preedit.isEmpty {
            CompositionPopup.shared.show(preedit: view.preedit, caret: view.caret, mark: view.mark,
                                         anchor: caretAnchor(client, length: view.preedit.utf16.count))
        } else {
            CompositionPopup.shared.hidePopup()
        }
        rendered = view
        UpdateController.setComposing(!view.preedit.isEmpty)
    }

    /// The preedit as clause segments, one per word (what vChewing and
    /// McBopomofo send): clients draw a break between segments with different
    /// `markedClauseSegment`, which is the split underline. Underline style
    /// 1 = single, 2 = thick (the cursor's word). Falls back to one segment
    /// when the ranges do not tile the preedit.
    static func markedText(_ view: SessionView) -> NSAttributedString {
        let units = Array(view.preedit.utf16)
        func plain() -> NSAttributedString {
            NSAttributedString(string: view.preedit, attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0])
        }
        guard view.segments.count > 1, view.segments.first?.lowerBound == 0,
              view.segments.last?.upperBound == units.count,
              zip(view.segments, view.segments.dropFirst()).allSatisfy({ $0.upperBound == $1.lowerBound }) else {
            return plain()
        }
        let out = NSMutableAttributedString()
        for (index, range) in view.segments.enumerated() {
            let thick = view.focus == range
            out.append(NSAttributedString(
                string: String(decoding: units[range], as: UTF16.self),
                attributes: [.underlineStyle: thick ? 2 : 1, .markedClauseSegment: index]))
        }
        return out
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

    // MARK: - IMK lifecycle

    override func menu() -> NSMenu! {
        Runtime.debugLog("[ime] menu() requested")
        let menu = NSMenu(title: "Misstype")
        menu.autoenablesItems = false
        // Persistent mode readout (the flash pill is transient): which
        // language bare keys will produce right now.
        let mode = NSMenuItem(title: Runtime.zigEngine.isEnglish ? L("English mode") : L("Chinese mode"),
                              action: nil, keyEquivalent: "")
        mode.state = .on
        mode.isEnabled = false
        menu.addItem(mode)
        // Per-app fallback for clients that draw no marked text (terminals in
        // Electron): the signal cannot be detected, so the user decides.
        // The bundle ID is cached while the client is live: asking a stale
        // client from menu() can raise an ObjC exception, which silently
        // dropped the whole menu.
        if let id = clientBundleID, !id.isEmpty {
            let popup = NSMenuItem(title: L("Floating composition in this app"),
                                   action: #selector(togglePopupComposition(_:)), keyEquivalent: "")
            // No target: IMK ships the menu to the system's input menu and
            // dispatches actions back to the controller by selector (as with
            // Settings…). A target object cannot cross that boundary, and the
            // whole input menu (icon included) disappeared with it.
            popup.target = nil
            popup.isEnabled = true
            popup.state = ClientMitigation.needsPopup(bundleID: id) ? .on : .off
            menu.addItem(popup)
        }
        let prefs = NSMenuItem(title: L("Settings…"), action: #selector(openPreferences(_:)), keyEquivalent: "")
        prefs.target = nil
        prefs.isEnabled = true
        menu.addItem(prefs)
        return menu
    }

    @objc func togglePopupComposition(_ sender: Any?) {
        guard let client = lastClient, let id = clientBundleID, !id.isEmpty else { return }
        ClientMitigation.togglePopup(bundleID: id)
        // Redraw under the new mode: end the composition so no stale marked
        // text stays in a client that will not show it (or the popup stays).
        commitComposition(client)
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
            clientBundleID = client.bundleIdentifier()
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

if CommandLine.arguments.contains("--session-trace") { runSessionTrace(arguments: CommandLine.arguments) }
if CommandLine.arguments.contains("--decode") {
    // The offline decode CLI moved out of the app with the Swift core.
    FileHandle.standardError.write(Data("--decode moved to core-zig/zig-out/bin/misstype-dev (docs/development.md)\n".utf8))
    exit(2)
}

ProcessInfo.processInfo.disableAutomaticTermination("MisstypeIME Input Method")
ProcessInfo.processInfo.disableSuddenTermination()

let app = NSApplication.shared
_ = Runtime.zigEngine
let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String ?? "org.misstype.inputmethod.Misstype_Connection"
guard NSClassFromString("MisstypeInputController") != nil,
      let bundleID = Bundle.main.bundleIdentifier,
      let server = IMKServer(name: connectionName, bundleIdentifier: bundleID) else {
    NSLog("Misstype: InputMethodKit initialization failed for \(connectionName)")
    exit(1)
}
/// Active controller for panel click routing (controllers are per-client).
weak var activeController: MisstypeInputController?
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

MisstypePrefs.register()
MainActor.assumeIsolated { UpdateController.shared.start() }
// Retained: DistributedNotificationCenter returns an opaque token that must
// stay alive, otherwise the observer is released immediately and the
// cross-process preferences trigger silently never fires.
var prefsObserver: NSObjectProtocol?
prefsObserver = DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("org.misstype.openPreferences"),
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
