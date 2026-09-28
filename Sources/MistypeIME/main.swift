import Cocoa
@preconcurrency import Carbon
@preconcurrency import InputMethodKit
import MistypeCore

enum Runtime {
    static let decoder: LexiconDecoder = {
        guard let url = Bundle.main.url(forResource: "lexicon", withExtension: "tsv"),
              let data = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("Mistype: missing lexicon; refusing to start with a fixture decoder")
            exit(1)
        }
        // Local supplement (Resources/local_phrases.tsv, optional): curated
        // high-frequency words missing upstream. Same shape, concatenated —
        // one parse path, first-class entries. Missing file means empty.
        let supplement = Bundle.main.url(forResource: "local_phrases", withExtension: "tsv")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return LexiconDecoder(tsv: data + "\n" + supplement)
    }()
    /// Explicit-opt-in user overlay, loaded once at startup and reloaded
    /// when the preference flips on. Gated per keystroke by
    /// MistypePrefs.userLearning — off means nil, i.e. byte-identical decode.
    static var userLexicon = UserLexicon.load()
    /// 中/英 mode: GLOBAL, not per-controller — one physical keyboard, all
    /// clients. (Per-controller state surprised users: toggling in one app
    /// never reached another.) Default Chinese on every launch.
    static var english = false
    /// Lone-Shift-tap state (single keyboard truth; reset on focus change).
    static var shiftTap = ShiftTapTracker()
    static var activeUserLexicon: UserLexicon? {
        MistypePrefs.userLearning ? userLexicon : nil
    }
    /// Recent committed sentences (in-memory only, never persisted): topic
    /// continuity for Jev runs across fields. Sent only under the same
    /// explicit Jev opt-in + key as user_context — same trust boundary, no
    /// wider. Capped small; trimming keeps one line per commit.
    static var recentCommits: [String] = []
    static let recentCommitCap = 5
    static let recentCommitChars = 48
    static func recordCommit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentCommits.append(String(trimmed.prefix(recentCommitChars)))
        if recentCommits.count > recentCommitCap {
            recentCommits.removeFirst(recentCommits.count - recentCommitCap)
        }
    }
    /// Pending Jev evaluations awaiting their commit verdict (in-memory,
    /// capped): the gate only fires on untouched states (no pins/picks), so
    /// the eventually committed text for the SAME raw keys is the honest
    /// ground truth for that evaluation. Acceptance, not correctness — a
    /// user override after the fact still grades 0.
    struct JevVerdict: Sendable {
        var rawKeys: String
        var pickedText: String
        var flip: Bool
        var confidence: Double
    }
    static var jevPending: [JevVerdict] = []
    static let jevPendingCap = 20
    static func noteJevEval(rawKeys: String, pickedText: String, flip: Bool, confidence: Double) {
        jevPending.append(JevVerdict(rawKeys: rawKeys, pickedText: pickedText, flip: flip, confidence: confidence))
        if jevPending.count > jevPendingCap {
            jevPending.removeFirst(jevPending.count - jevPendingCap)
        }
    }
    /// Grade by exact raw-keys match (anything typed after the evaluation
    /// changes the keys, so only clean Return-commits of the evaluated state
    /// grade). Logs booleans only — never text (repo policy).
    static func gradeJevEval(rawKeys: String, committed: String) {
        guard let index = jevPending.firstIndex(where: { $0.rawKeys == rawKeys }) else { return }
        let verdict = jevPending.remove(at: index)
        debugLog("jev-grade accept=\(verdict.pickedText == committed ? 1 : 0) flip=\(verdict.flip ? 1 : 0) conf=\(String(format: "%.2f", verdict.confidence))")
    }
    /// Jev gateway policy, read live per keystroke like the other prefs.
    /// Default off: `canAttempt == false` means decode stays byte-identical
    /// to the offline path. When the user explicitly enables it AND provides
    /// a key, a debounced remote Choice request runs on settled ties
    /// (scheduleJevEvaluation) and may move the highlight; the gate trace
    /// logs presence only (never the key or text).
    static var jevConfig: JevConfig { MistypePrefs.jevConfig }
    /// Presence-only gate trace (never the key or text). Called on every
    /// decode entry point so remote intent stays observable per policy.
    static func logJevGate() {
        let jev = jevConfig
        debugLog("jev enabled=\(jev.enabled ? 1 : 0) rich=\(jev.allowRichContext ? 1 : 0) key=\(jev.hasKey ? 1 : 0)")
    }
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

@objc(MistypeInputController)
final class MistypeInputController: IMKInputController {    private var composition = Composition()
    private var candidates: [SentenceCandidate] = []
    private var selected = 0
    private weak var lastClient: IMKTextInput?
    /// Latin-run mode (backtick toggles): letter keys append verbatim and
    /// keep composing — no Shift toggle, no pause. Tone/space/punct/digits
    /// and commit end the run; see the letter branch below.
    private var latinMode = false
    /// Explicitly picked text (Tab/arrows/digit/click). Survives continued
    /// typing by prefix match: longer candidates extending the pick keep it.
    /// Cleared on commit/clear/Escape or when no candidate extends it.
    /// `explicitPick` is the learning-grade subset: true only when the pick
    /// came from a deliberate selection gesture — separator/punctuation
    /// pinning sets pinnedPick without it, so routine commits never train.
    private var pinnedPick: String?
    private var explicitPick = false
    /// Syllable cursor (nil = end of the converted span). Plain Left/Right
    /// move it instead of flipping pages; the panel then shows options for
    /// the focused word span. Any composition edit resets it to end.
    /// Replaces the old Opt+Right segment lock (dead in practice: toneless
    /// input only beeped, fully toned input committed exactly like Return).
    private var cursor: Int?
    /// Focused options (nil = whole-span list): every word covering the
    /// cursor syllable, each with its own span. Picking pins that span into
    /// sessionPins and advances the cursor past it; pins hold until
    /// commit/clear/Escape and never touch disk.
    private var segmentTexts: [String]?
    private var segmentOptions: [CursorOption] = []
    private var segmentSelected = 0
    /// UTF-16 offset of the cursor syllable (caret for marked text/panel).
    private var segmentCaret: Int?
    private var sessionPins = UserLexicon()
    /// Automatic pins for accepted text (earlier runs, and words 3+
    /// syllables before the end): re-derived from top-1 every refresh, kept
    /// apart from explicit sessionPins so they never train, and dropped
    /// whenever an explicit pick lands (the next refresh re-derives them).
    private var settledPins = UserLexicon()
    private static let settleDistance = 3
    /// Pending keys shown raw after the live conversion: the syllable still
    /// being typed (`livePendingCut`). Empty = everything on screen converted.
    private var rawTail: [String] = []
    /// Selection mode (end-of-span list): entered with Down/Up/Tab. The
    /// cursor's focused list is selection mode too (`inSelection`). Only in
    /// it do the selection keys (MistypePrefs.candidateKeys, home row by
    /// default) pick — they are Zhuyin keys everywhere else. Any other
    /// typing leaves the mode; Esc leaves it without touching the text.
    private var selecting = false
    private var inSelection: Bool { selecting || segmentTexts != nil }
    private let missingRange = NSRange(location: NSNotFound, length: 0)
    private var jevRequestID = 0
    private let jevLock = NSLock()

    private func nextJevID() -> Int {
        jevLock.lock()
        defer { jevLock.unlock() }
        jevRequestID += 1
        return jevRequestID
    }

    private func currentJevID() -> Int {
        jevLock.lock()
        defer { jevLock.unlock() }
        return jevRequestID
    }

    /// Shared 中/英 toggle entry (Shift-tap and Shift+Space): commit first
    /// so no composition is lost, then flip the global mode with a flash.
    private func setEnglish(_ on: Bool, client: IMKTextInput) {
        // Anchor BEFORE commit: afterwards the marked text (and its caret
        // rect) is gone and the pill would fall back to the mouse.
        let anchor = caretAnchor(client)
        commit(client)
        Runtime.english = on
        latinMode = false
        ModeIndicator.shared.flash(english: on, anchor: anchor)
    }

    /// Raw event inlet (vChewing parity): this controller deliberately does
    /// NOT implement `inputText:key:modifiers:client:` — when it does, the
    /// server takes the managed path and `handleEvent` never fires (verified
    /// 2026-09-18: mask queried fresh, inputText served, handleEvent dead).
    /// Without it, the server delivers raw NSEvents here for every masked
    /// type, and text is parsed below exactly once. NSEvent shadow classes:
    /// never touch `.characters` on non-keyDown events (throws).
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags
        let shiftHeld = flags.contains(.shift)
        let isShiftKey = ShiftTapTracker.shiftKeyCodes.contains(keyCode)
        let otherMods = flags.contains(.command) || flags.contains(.control)
            || flags.contains(.option) || flags.contains(.capsLock)
        switch event.type {
        case .flagsChanged, .keyUp:
            // Modifier-only signals: tap bookkeeping, then consume (no text).
            let tap = Runtime.shiftTap.feed(keyCode: keyCode, shiftHeld: shiftHeld,
                                            isRealKeyDown: false, otherMods: otherMods)
            if tap, MistypePrefs.shiftToggle, let client = sender as? IMKTextInput {
                lastClient = client
                activeController = self
                setEnglish(!Runtime.english, client: client)
            }
            return true
        case .keyDown:
            if isShiftKey {
                // Bare-modifier press (press-as-keyDown delivery): arm only.
                _ = Runtime.shiftTap.feed(keyCode: keyCode, shiftHeld: shiftHeld,
                                          isRealKeyDown: false, otherMods: otherMods)
                return true
            }
            _ = Runtime.shiftTap.feed(keyCode: keyCode, shiftHeld: shiftHeld,
                                      isRealKeyDown: true, otherMods: otherMods)
            guard let client = sender as? IMKTextInput else { return false }
            lastClient = client
            activeController = self
            // Bare-modifier keyDowns (Caps/Opt/Ctrl alone) carry no text:
            // consume silently instead of committing the composition first
            // (the old managed path committed+passed them through).
            guard !Self.isBareModifier(keyCode: keyCode, string: event.characters) else { return true }
            return handleInputText(event.characters, key: keyCode,
                                   modifiers: Int(flags.rawValue), client: client)
        default:
            return false
        }
    }

    /// Modifier keyCodes that never produce text on their own keyDown.
    private static func isBareModifier(keyCode: Int, string: String?) -> Bool {
        if let string, !string.isEmpty { return false }
        // ANSI modifiers: Shift 56/60, Ctrl 59/62, Opt 58/61, Cmd 55/54, Caps 57, Fn 63, Help 114.
        return [55, 54, 56, 57, 58, 59, 60, 61, 62, 63, 114].contains(keyCode)
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue
            | NSEvent.EventTypeMask.flagsChanged.rawValue
            | NSEvent.EventTypeMask.keyUp.rawValue)
    }

    /// Text inlet, called ONLY from handleEvent above (never by the server:
    /// this name deliberately differs from `inputText:key:modifiers:client:`
    /// so the server takes the raw handleEvent path — see handle(_:client:)).
    /// Identical contract to the old override: string may be nil (special
    /// keys), keyCode is the ANSI code, flags the modifier bits.
    func handleInputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool {
        guard let client = sender as? IMKTextInput else { return false }
        lastClient = client
        activeController = self
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(flags))
        // Key trace for routing diagnosis (codes only, never text content).
        Runtime.debugLog("key=\(keyCode) flags=\(flags) comp=\(composition.isEmpty ? 0 : 1) sel=\(selected) n=\(candidates.count) cur=\(cursor ?? -1) seg=\(segmentTexts == nil ? 0 : 1)")
        // Defensive nil-guard: string is implicitly unwrapped and later code
        // calls string.count — an empty/nil event carries no text either way.
        if string == nil || string!.isEmpty {
            return true
        }
        if keyCode == 49 && modifiers.contains(.shift) {
            setEnglish(!Runtime.english, client: client)
            return true
        }
        if Runtime.english || modifiers.contains(.capsLock) { commit(client); return false }
        // Latin mode ends on anything but letters, space (multi-word runs
        // stay latin: `hello world`), and the backtick toggle: tones,
        // punctuation, digits and commit keys resume Zhuyin.
        let latinLetter: Bool = {
            guard latinMode, !Runtime.english,
                  !modifiers.contains(.command), !modifiers.contains(.control),
                  !modifiers.contains(.option),
                  let label = ZhuyinKeyboard.labels[keyCode],
                  label.count == 1, let scalar = label.unicodeScalars.first,
                  CharacterSet.letters.contains(scalar) else { return false }
            return true
        }()
        if !latinLetter && keyCode != 50 && keyCode != 49 { latinMode = false }
        // Destructive editing is handled before the generic modifier
        // commit-passthrough further below, so deleting phonetic evidence
        // never commits the composition first.
        if keyCode == 51 {
            guard !composition.isEmpty else { return false }
            selected = 0
            if modifiers.contains(.command) {
                _ = nextJevID()
                composition.clear()
                candidates = []
                rawTail = []
                settledPins = UserLexicon()
                selecting = false
                pinnedPick = nil
                explicitPick = false
                cursor = nil
                clearSegment()
                sessionPins = UserLexicon()
                selected = 0
                latinMode = false
                mark("", client)
                candidatePanel.hidePanel()
            } else if modifiers.contains(.option) {
                composition.deleteLastSyllable()
                refresh(client)
            } else {
                composition.erase()
                refresh(client)
            }
            return true
        }
        if keyCode == 117 { // forward delete: caret sits after marked text
            guard !composition.isEmpty else { return false }
            commit(client)
            return false
        }
        if keyCode == 125 || keyCode == 126 { // Down/Up step candidates
            guard !composition.isEmpty else { return false }
            if let texts = segmentTexts, !texts.isEmpty {
                // Focused mode: move the segment highlight only — nothing
                // pins until Tab/digit/click/Return confirms. Consumed even
                // for a single option so the preview never jumps invisibly.
                segmentSelected = (segmentSelected + (keyCode == 125 ? 1 : texts.count - 1)) % texts.count
                mark(previewText, client)
                syncPanel(client)
                return true
            }
            if candidates.count > 1 {
                selected = (selected + (keyCode == 125 ? 1 : candidates.count - 1)) % candidates.count
                pinnedPick = candidates[selected].text
                explicitPick = true
                selecting = true
                mark(previewText, client)
                syncPanel(client)
                return true
            }
            commit(client)
            return false
        }
        // Modified arrows never edit the composition: commit first, then let
        // the app move its caret (word jump, line start, selection). Plain
        // arrows below drive the syllable cursor / candidate list instead.
        if (keyCode == 123 || keyCode == 124)
            && (modifiers.contains(.option) || modifiers.contains(.command)
                || modifiers.contains(.control)) {
            commit(client)
            return false
        }
        if keyCode == 123 || keyCode == 124 { // Left/Right: syllable cursor only.
            // Paging used to live here as a fallback, which made the arrows
            // unpredictable (cursor sometimes, page-flip others, so stepping
            // back usually paged instead). Paging is Tab / Shift+Tab /
            // Down / Up's job (they walk the full list across pages), so
            // arrows never flip pages: failure beeps and stays put.
            guard !composition.isEmpty else { return false }
            if keyCode == 123 {
                if moveCursorBack(client) { return true }
            } else if moveCursorForward(client) { return true }
            NSSound.beep()
            return true
        }
        if keyCode == 53 {
            guard !composition.isEmpty else { return false }
            if inSelection {
                // First Esc only leaves selection mode (and the cursor);
                // the text and any picks stay. A second Esc clears.
                selecting = false
                cursor = nil
                clearSegment()
                syncPanel(client)
                mark(previewText, client)
                return true
            }
            _ = nextJevID()
            composition.clear()
            candidates = []
            rawTail = []
            settledPins = UserLexicon()
            selecting = false
            pinnedPick = nil
            explicitPick = false
            cursor = nil
            clearSegment()
            sessionPins = UserLexicon()
            selected = 0
            latinMode = false
            mark("", client)
            candidatePanel.hidePanel()
            return true
        }
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
            commit(client)
            return false
        }
        if keyCode == 36 || keyCode == 76 {
            guard !composition.isEmpty else { return false }
            if modifiers.contains(.shift) {
                // Shift+Return sends the keys as typed: 注音文 even when every
                // syllable is valid (a lone ㄗ is 資 to the decoder).
                commit(client, raw: true)
                return true
            }
            if let texts = segmentTexts, texts.indices.contains(segmentSelected) {
                // Focused Return pins the highlighted segment, re-decodes so
                // top-1 honors it, then commits everything at once.
                pinAdvance(client, at: segmentSelected)
                selected = 0
            }
            commit(client)
            return true
        }
        if keyCode == 48 && !composition.isEmpty {
            if let texts = segmentTexts, texts.indices.contains(segmentSelected) {
                // Focused Tab pins without committing: Left…Tab,Tab,Return
                // fixes two mid-sentence words and sends the sentence.
                pinAdvance(client, at: segmentSelected)
                return true
            }
            if candidates.count > 1 {
                // Tab steps forward, Shift+Tab steps back (Tab reliably
                // reaches the IME; arrows are often eaten by the client app
                // or the panel before inputText ever runs).
                let backward = modifiers.contains(.shift)
                selected = (selected + (backward ? candidates.count - 1 : 1)) % candidates.count
                pinnedPick = candidates[selected].text
                explicitPick = true
                selecting = true
                mark(previewText, client)
                syncPanel(client)
            }
            return true
        }
        // Backtick toggles latin-run mode (no modifiers, either language
        // mode off): following letters append verbatim. Swallowed silently —
        // the letters themselves are the feedback. Shift+` is ～ (Punctuation).
        if keyCode == 50 && !modifiers.contains(.shift) && !modifiers.contains(.command)
            && !modifiers.contains(.control) && !modifiers.contains(.option) && !Runtime.english {
            latinMode.toggle()
            Runtime.debugLog("latin=\(latinMode ? 1 : 0)")
            return true
        }
        // Selection keys pick from the visible page, but only in selection
        // mode: they are Zhuyin keys (a=ㄇ, s=ㄋ, …), so outside it they type.
        // Shift+digit used to pick; that row is now the full-width symbol
        // layer (Punctuation), so picking and symbols never collide.
        if inSelection, !composition.isEmpty, !modifiers.contains(.shift),
           let label = ZhuyinKeyboard.labels[keyCode],
           let slot = SelectionKeys.slot(forLabel: label, keys: MistypePrefs.candidateKeys) {
            if let texts = segmentTexts {
                let global = (segmentSelected / 8) * 8 + slot
                if global < texts.count { pinAdvance(client, at: global) } else { NSSound.beep() }
                return true
            }
            let global = (selected / 8) * 8 + slot
            if global < candidates.count {
                selected = global
                pinnedPick = candidates[selected].text
                explicitPick = true
                selecting = false
                mark(previewText, client)
                syncPanel(client)
            } else {
                NSSound.beep()
            }
            return true
        }
        // CJK punctuation locks the current pick and continues: pin the
        // selection, append the mark, refresh. Never commits — commit is
        // Return's job. Checked before the generic modifier passthrough and
        // the phonetic path. Cmd shortcuts are never hijacked: the table
        // only matches listed combos and Cmd is excluded.
        if !modifiers.contains(.command),
           let punct = Punctuation.output(keyCode: keyCode,
                                          shift: modifiers.contains(.shift),
                                          ctrl: modifiers.contains(.control)) {
            if candidates.indices.contains(selected) {
                pinnedPick = candidates[selected].text
            }
            if composition.appendLiteral(punct) {
                refresh(client)
            } else {
                NSSound.beep()
            }
            return true
        }
        // Latin-run letters append verbatim (case from the event string) and
        // keep composing — the seamless path, no mode toggle involved.
        if latinLetter, string.count == 1, let char = string.first,
           char.isASCII, char.isLetter {
            if composition.appendLatin(String(char)) { refresh(client); return true }
            NSSound.beep()
            return true
        }
        // Shift-hold Latin: Shift+letter always appends the literal inline
        // (case from the event) and keeps composing — no commit, no mode
        // toggle. A fast-typing Shift brush leaves a stray capital in marked
        // text instead of chopping the sentence.
        if modifiers.contains(.shift), !modifiers.contains(.command),
           !modifiers.contains(.control), !modifiers.contains(.option),
           let label = ZhuyinKeyboard.labels[keyCode],
           label.count == 1,
           label.unicodeScalars.first.map(CharacterSet.letters.contains) == true,
           string.count == 1, let char = string.first,
           char.isASCII, char.isLetter {
            if composition.appendLatin(String(char)) { refresh(client); return true }
            NSSound.beep()
            return true
        }
        if modifiers.contains(.shift) {
            if ZhuyinKeyboard.labels[keyCode] == nil || composition.isEmpty {
                commit(client)
                return false
            }
        }
        if let key = ZhuyinKeyboard.labels[keyCode] {
            if key == " " {
                // Space with pending keys is a tone mark (continue).
                // Otherwise Space pins the current pick and continues as a
                // literal separator — commit is Return's job. Empty
                // composition passes the space straight through.
                guard !composition.isEmpty else {
                    client.insertText(" ", replacementRange: missingRange)
                    return true
                }
                if !composition.parsed.pending.isEmpty {
                    if composition.appendSpace() { refresh(client); return true }
                    NSSound.beep()
                    return true
                }
                if candidates.indices.contains(selected) {
                    pinnedPick = candidates[selected].text
                }
                if composition.appendSpace() { refresh(client); return true }
                NSSound.beep()
                return true
            }
            if composition.append(key) { refresh(client); return true }
            // A tone with no pending syllable is a late or corrected tone:
            // attach it to the last boundary instead of swallowing it.
            if ZhuyinKeyboard.tones[key] != nil, composition.retoneLast(key) {
                refresh(client)
                return true
            }
            NSSound.beep()
            return true
        }
        commit(client)
        return false
    }

    private var previewText: String {
        let converted = candidates.indices.contains(selected) ? candidates[selected].text : ""
        return converted + rawTail.compactMap { ZhuyinKeyboard.symbols[$0] }.joined()
    }
    /// Caret shared by marked text and the panel header: focused word start,
    /// else after the last unit. UTF-16 offsets throughout.
    private var caretOffset: Int {
        let len = previewText.utf16.count
        if let focused = segmentCaret { return min(focused, len) }
        return len
    }
    /// Safely extracts preceding text context and bundle identifier from the client.
    private func currentContext(_ client: IMKTextInput) -> ClientContext {
        let adapter = IMKTextInputContextAdapter(client)
        return SurroundingContext.extract(from: adapter)
    }
    private func refresh(_ client: IMKTextInput, keepCursor: Bool = false) {
        // Preview converts every run, the pending one live (below);
        // punctuation passes through in place.
        let previous = candidates.map(\.text)
        // Jev gate threads through every decode entry point but changes
        // nothing while off (the default): the offline decode below is the
        // single source of candidates. Presence-only logging keeps remote
        // intent observable per repo policy without leaking key or text.
        Runtime.logJevGate()
        // Live conversion (RIME-style continuous typing): the pending run
        // converts as it is typed, except the syllable still in progress,
        // which stays raw (`livePendingCut`). Space is a first-tone key, not
        // a "convert" key, so nothing waits for it.
        // A whole-sentence pick becomes positional pins before re-decoding,
        // so re-segmentation of the live tail cannot drop it.
        if !keepCursor, pinnedPick != nil, selected != 0, candidates.indices.contains(selected) {
            sessionPins.pinDifferences(of: candidates[selected], from: candidates[0])
            settledPins = UserLexicon()
        }
        let live = Runtime.decoder.livePreview(composition, fuzzy: MistypePrefs.fuzzyRepair,
                                               toneTolerance: MistypePrefs.toneTolerance,
                                               userLexicon: Runtime.activeUserLexicon,
                                               locked: sessionPins.isEmpty ? nil : sessionPins,
                                               settled: settledPins.isEmpty ? nil : settledPins)
        rawTail = live.rawTail
        candidates = live.candidates
        if let top = candidates.first {
            settledPins = UserLexicon.settled(from: top, keep: Self.settleDistance)
        }
        if let pin = pinnedPick, !pin.isEmpty {
            if let exact = candidates.firstIndex(where: { $0.text == pin }) {
                selected = exact
            } else if let extended = candidates.firstIndex(where: { $0.text.hasPrefix(pin) }) {
                selected = extended
            } else {
                selected = 0
                pinnedPick = nil
                explicitPick = false
            }
        } else if candidates.map(\.text) != previous || !candidates.indices.contains(selected) {
            selected = 0
        }
        // Composition edits return the cursor to end (pins survive — they
        // are reading-keyed, so tail typing keeps them); pin-advance passes
        // keepCursor to stay focused on the next span.
        if !keepCursor {
            cursor = nil
            selecting = false
        }
        if cursor != nil {
            focusSegment()
        } else {
            clearSegment()
        }
        syncPanel(client)
        mark(previewText, client)
        scheduleJevEvaluation(client: client)
    }
    /// Push our truth to the panel (highlight included — single owner, no
    /// echo loop possible since the panel never calls back). Focused mode
    /// shows the segment list; end mode the whole-span list.
    private func syncPanel(_ client: IMKTextInput) {
        let texts = segmentTexts ?? candidates.map(\.text)
        let sel = segmentTexts != nil ? segmentSelected : selected
        // Focused mode shows even a single option: the header carries the
        // cursor, which is the whole point of going back. End mode keeps the
        // out-of-the-way policy (only >1 candidate).
        let show = segmentTexts != nil ? !texts.isEmpty : texts.count > 1
        if show {
            candidatePanel.update(candidates: texts,
                                  selected: sel,
                                  keyLabels: SelectionKeys.labels(keys: MistypePrefs.candidateKeys),
                                  keysActive: inSelection,
                                  anchor: caretAnchor(client),
                                  preedit: previewText,
                                  caret: caretOffset)
        } else {
            candidatePanel.hidePanel()
        }
    }
    /// Caret rect in screen coordinates for panel placement (McBopomofo-style:
    /// walk back from the end of marked text until a non-zero line height
    /// rect comes back). Logs the outcome class (numbers only): 1 = client
    /// reports only zero rects, 2 = positioned.
    private func caretAnchor(_ client: IMKTextInput) -> NSRect? {
        var rect = NSRect(x: 0, y: 0, width: 16, height: 16)
        var cursor = (previewText as NSString).length
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
        if let texts = segmentTexts, texts.indices.contains(index) {
            guard let client = lastClient else { return }
            pinAdvance(client, at: index)
            return
        }
        guard candidates.indices.contains(index) else { return }
        selected = index
        pinnedPick = candidates[index].text
        explicitPick = true
        selecting = false
        if let client = lastClient {
            mark(previewText, client)
            syncPanel(client)
        }
    }
    private func mark(_ text: String, _ client: IMKTextInput) {
        // Focused mode parks the caret at the start of the focused word;
        // end mode keeps it after the last unit (converted or pending raw).
        client.setMarkedText(text, selectionRange: NSRange(location: caretOffset, length: 0),
                             replacementRange: missingRange)
    }
    private func scheduleJevEvaluation(client: IMKTextInput) {
        let requestID = nextJevID()
        let config = MistypePrefs.jevConfig
        // Never while the pending run is still growing: live conversion
        // re-decodes it every keystroke, and asking then would send a request
        // per typing pause (Jev saw only terminated runs before live
        // conversion; this keeps that request rate).
        guard config.canAttempt,
              !composition.isEmpty,
              composition.parsed.pending.isEmpty, rawTail.isEmpty,
              candidates.count > 1,
              pinnedPick == nil,
              !explicitPick,
              segmentTexts == nil else { return }
        // Decisive-offline filter first: a top-1 lead past repair scale
        // means the phonetic evidence already decided — skip before any XPC.
        let margin = candidates[0].score - candidates[1].score
        // Surrounding-text lookup is an XPC round-trip into the client on the
        // IMK main thread, and legacy client wrappers (notably Chromium /
        // Electron) have segfaulted inside stringFromRange:actualRange: (see
        // DiagnosticReports 2026-09-17). It runs ONLY here, after the gates
        // above, when Jev will genuinely attempt a request — never on the hot
        // path for offline decoding.
        let context = currentContext(client)
        Runtime.debugLog("context chars=\(context.precedingText.count) app=\(context.bundleIdentifier ?? "none")")
        // Span counts complete syllables plus the segmented pending tail:
        // toneless typing never terminates pending, but its multi-syllable
        // runs are still worth asking about.
        let parsed = composition.parsed
        var syllableCount = parsed.complete.count
        if !parsed.pending.isEmpty,
           let tail = Runtime.decoder.segmentKeys(
               parsed.pending, fuzzy: MistypePrefs.fuzzyRepair,
               toneTolerance: MistypePrefs.toneTolerance).first {
            syllableCount += tail.count
        }
        let hasContext = !context.precedingText.isEmpty
        guard JevTrigger.shouldAttempt(syllableCount: syllableCount,
                                       topMargin: margin,
                                       hasContext: hasContext) else {
            Runtime.debugLog("jev skip=\(JevTrigger.skipCode(syllableCount: syllableCount, topMargin: margin, hasContext: hasContext))")
            return
        }

        let rawKeys = composition.rawKeys.joined()
        // Evidence = the syllables the candidates were decoded from; the
        // composition's segments hold a toneless run as ONE fused syllable.
        let evidence = candidates[0].syllables.map { JevState.Evidence(base: $0.base, tone: $0.tone) }
        let candTuples = Array(candidates.prefix(8)).map {
            (text: $0.text, score: $0.score, repairs: $0.repairs, unresolved: $0.unresolved)
        }
        let userCtx = context.precedingText
        // Learned picks for exactly these readings (harness parity), plus
        // recent commits for topic continuity. Both ride the same explicit
        // opt-in as the request itself; learning-off means no preferences.
        let prefs = Runtime.activeUserLexicon?.matchingPreferences(
            forBases: evidence.map(\.base)) ?? []
        let recent = Runtime.recentCommits
        Runtime.debugLog("jev prefs=\(prefs.count) recent=\(recent.count)")

        Task.detached { [weak self] in
            // Debounce 120ms: fast typing supersedes this request without hitting the network
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self = self, self.currentJevID() == requestID else { return }

            Runtime.debugLog("[jev-api] start model=\(config.model) cands=\(candTuples.count) ctxChars=\(userCtx.count)")
            let t0 = DispatchTime.now()
            do {
                let result = try await JevClient.evaluate(
                    config: config,
                    rawKeys: rawKeys,
                    evidence: evidence,
                    candidates: candTuples,
                    userContext: userCtx,
                    userPreferences: prefs,
                    recentCommits: recent,
                    richContext: config.allowRichContext,
                    timeoutInterval: 1.2
                )
                let elapsedMs = Int(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)
                DispatchQueue.main.async {
                    guard let client = self.lastClient,
                          self.currentJevID() == requestID,
                          !self.composition.isEmpty,
                          self.pinnedPick == nil,
                          !self.explicitPick,
                          self.segmentTexts == nil else {
                        Runtime.debugLog("[jev-api] stale ms=\(elapsedMs)ms (superseded)")
                        return
                    }
                    let targetIndex = result.pickedIndex - 1
                    let flip = targetIndex != self.selected
                    Runtime.debugLog("[jev-api] ok ms=\(elapsedMs)ms pick=\(result.pickedIndex):\(result.pickedText) conf=\(String(format: "%.2f", result.confidence)) flip=\(flip ? 1 : 0)")
                    Runtime.noteJevEval(rawKeys: rawKeys, pickedText: result.pickedText, flip: flip, confidence: result.confidence)
                    if flip && self.candidates.indices.contains(targetIndex) {
                        self.selected = targetIndex
                        self.syncPanel(client)
                        self.mark(self.previewText, client)
                    }
                }
            } catch {
                let elapsedMs = Int(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)
                Runtime.debugLog("[jev-api] err ms=\(elapsedMs)ms \(error.localizedDescription)")
            }
        }
    }

    private func commit(_ client: IMKTextInput, raw: Bool = false) {
        guard !composition.isEmpty else { return }
        var text: String
        // What you see is what commits: the converted text plus any raw
        // tail exactly as shown, so a trailing ㄉ (or a whole run typed as
        // 注音文) commits as Bopomofo instead of being "repaired" into a char
        // the preview never showed (user decision 2026-09-27).
        // Learning-grade: nothing left raw and an explicit pick. Anything
        // else — raw tail, separator pinning, raw fallback — never trains.
        let learnable = !raw && rawTail.isEmpty && candidates.indices.contains(selected)
        text = raw ? composition.rawPhonetic : previewText
        if text.isEmpty {
            // Defensive: nothing rendered yet (no refresh since the last
            // edit). Offline recompute, Jev gate closed as in refresh.
            Runtime.logJevGate()
            text = Runtime.decoder.decodeSegments(composition.segments,
                                                  pendingKeys: composition.parsed.pending,
                                                  fuzzy: MistypePrefs.fuzzyRepair,
                                                  toneTolerance: MistypePrefs.toneTolerance,
                                                  userLexicon: Runtime.activeUserLexicon,
                                                  locked: sessionPins.isEmpty ? nil : sessionPins).first?.text
                ?? composition.rawPhonetic
        }
        while text.last?.isWhitespace == true { text.removeLast() }
        guard !text.isEmpty else { return }
        // Success-rate verdict for any evaluation of exactly this state.
        Runtime.gradeJevEval(rawKeys: composition.rawKeys.joined(), committed: text)
        // Topic continuity for future Jev runs (in-memory ring, never disk).
        Runtime.recordCommit(text)
        if MistypePrefs.userLearning && explicitPick && learnable {
            // Word-level: cursor picks still pinned, words changed by a
            // whole-sentence pick, or the input when it is one word.
            let words = UserLexicon.learnedWords(committed: candidates[selected], pins: sessionPins,
                                                 baseline: selected == 0 ? nil : candidates[0])
            for word in words { Runtime.userLexicon.record(key: word.key, text: word.text) }
            if !words.isEmpty { Runtime.userLexicon.save() }
        }
        client.insertText(text, replacementRange: missingRange)
        _ = nextJevID()
        composition.clear()
        candidates = []
        rawTail = []
        settledPins = UserLexicon()
        selecting = false
        pinnedPick = nil
        explicitPick = false
        cursor = nil
        clearSegment()
        sessionPins = UserLexicon()
        selected = 0
        latinMode = false
        candidatePanel.hidePanel()
    }
    override func menu() -> NSMenu! {
        Runtime.debugLog("[ime] menu() requested")
        let menu = NSMenu(title: "Mistype")
        menu.autoenablesItems = false
        // Persistent mode readout (the flash pill is transient): which
        // language bare keys will produce right now.
        let mode = NSMenuItem(title: Runtime.english ? "英文 English ✓" : "中文 Chinese ✓",
                              action: nil, keyEquivalent: "")
        mode.isEnabled = false
        menu.addItem(mode)
        let prefs = NSMenuItem(title: "Mistype Preferences…", action: #selector(openPreferences(_:)), keyEquivalent: "")
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
            PreferencesPanel.shared.show()
        }
    }

    // MARK: - Syllable cursor (go back and pick a word, no modifiers)
    private struct FocusFrame {
        let syllables: [Syllable] // the top candidate's own decoded syllables
        let top: SentenceCandidate
    }
    /// The cursor indexes the syllables the top candidate was decoded from
    /// (`SentenceCandidate.syllables`), never a list rebuilt from the
    /// composition: repair and pending-run segmentation happen inside the
    /// decoder, so a toneless run is ONE fused syllable in the composition
    /// and the old rebuild-and-compare check rejected every toneless
    /// sentence (Left/Right only beeped). The live-converted pending run is
    /// included (it is in the alignment); only the raw tail is not.
    /// Works across separators: syllable indexes are global, and options
    /// stay inside the cursor's own run (`run(containing:)`).
    private func focusFrame() -> FocusFrame? {
        guard candidates.indices.contains(selected) else { return nil }
        let top = candidates[selected]
        // Unresolved (raw fallback) spans stay out: nothing to offer there.
        guard top.unresolved == 0,
              let end = top.alignment.last?.syllables.upperBound, end > 0,
              top.syllables.count == end else { return nil }
        return FocusFrame(syllables: top.syllables, top: top)
    }
    private func spanText(_ text: String, _ chars: Range<Int>) -> String? {
        let units = Array(text.utf16)
        guard chars.lowerBound >= 0, chars.upperBound <= units.count else { return nil }
        return String(decoding: units[chars], as: UTF16.self)
    }
    private func clearSegment() {
        segmentTexts = nil
        segmentOptions = []
        segmentSelected = 0
        segmentCaret = nil
    }
    /// Point the cursor at its syllable: list every word covering it
    /// (`cursorOptions`, longest first), so a fix needing a different word
    /// boundary (大|對 -> 打對) is one pick. The highlight starts on what is
    /// displayed now: the top path's word there, else the single character.
    /// Outcomes are traced by code (numbers only): ok, noframe, noword.
    private func focusSegment() {
        clearSegment()
        guard let c = cursor, let frame = focusFrame(),
              let word = frame.top.alignment.first(where: { $0.syllables.contains(c) }),
              let caret = frame.top.charOffset(ofSyllable: c) else {
            Runtime.debugLog("focus noframe")
            cursor = nil
            return
        }
        var options = Runtime.decoder.cursorOptions(
            frame.syllables, at: c, within: frame.top.run(containing: c),
            fuzzy: MistypePrefs.fuzzyRepair, toneTolerance: MistypePrefs.toneTolerance)
        let shownWord = spanText(frame.top.text, word.chars)
        let shownChar = spanText(frame.top.text, caret..<caret + 1)
        // Multi-syllable spans keep only their best few words, so a word
        // shown thanks to learning can fall outside the list; highlighting
        // a single char instead would let Return re-pin (and rewrite) it.
        // Keep the displayed word listed, at the end of its length group.
        if let shownWord, !options.contains(where: { $0.span == word.syllables && $0.text == shownWord }) {
            let at = options.firstIndex(where: { $0.span.count < word.syllables.count }) ?? options.count
            options.insert(CursorOption(text: shownWord, span: word.syllables, score: -.infinity), at: at)
        }
        guard let current = options.firstIndex(where: { $0.span == word.syllables && $0.text == shownWord })
                ?? options.firstIndex(where: { $0.span == c..<c + 1 && $0.text == shownChar }) else {
            Runtime.debugLog("focus noword")
            cursor = nil
            return
        }
        Runtime.debugLog("focus ok s=\(c) n=\(options.count) cur=\(current)")
        segmentOptions = options
        segmentTexts = options.map(\.text)
        segmentSelected = current
        segmentCaret = caret
    }
    private func moveCursorBack(_ client: IMKTextInput) -> Bool {
        guard let frame = focusFrame(),
              let end = frame.top.alignment.last?.syllables.upperBound, end > 0 else { return false }
        cursor = max((cursor ?? end) - 1, 0)
        focusSegment()
        syncPanel(client)
        mark(previewText, client)
        return true
    }
    private func moveCursorForward(_ client: IMKTextInput) -> Bool {
        guard cursor != nil, let frame = focusFrame(),
              let end = frame.top.alignment.last?.syllables.upperBound else { return false }
        cursor = cursor! + 1
        if cursor! >= end { cursor = nil }
        focusSegment()
        syncPanel(client)
        mark(previewText, client)
        return true
    }
    /// Pin a focused option: session-scoped decisive bonus (never disk) that
    /// changes only the option's span — overlapping older picks keep their
    /// characters outside it (`UserLexicon.pin(_:over:)`). Whole-text pin is
    /// cleared so the two never fight; the pick counts as explicit for
    /// user-phrase learning at commit.
    private func pinAdvance(_ client: IMKTextInput, at index: Int) {
        guard segmentOptions.indices.contains(index), let frame = focusFrame() else { return }
        let option = segmentOptions[index]
        sessionPins.pin(option, over: frame.top)
        settledPins = UserLexicon()
        pinnedPick = nil
        explicitPick = true
        cursor = option.span.upperBound
        refresh(client, keepCursor: true)
    }
    override func originalString(_ sender: Any!) -> NSAttributedString { NSAttributedString(string: composition.rawPhonetic) }
    override func commitComposition(_ sender: Any!) {
        if let client = sender as? IMKTextInput { commit(client) }
    }
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        activeController = self
        if let client = sender as? IMKTextInput {
            lastClient = client
        }
        Runtime.shiftTap.reset()
        Runtime.debugLog("[ime] activateServer")
    }

    override func deactivateServer(_ sender: Any!) {
        Runtime.debugLog("[ime] deactivateServer")
        Runtime.shiftTap.reset()
        commitComposition(sender)
        super.deactivateServer(sender)
    }
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
            let preview = decoder.livePreview(compose(keys.prefix(count)), fuzzy: MistypePrefs.fuzzyRepair,
                                              toneTolerance: MistypePrefs.toneTolerance,
                                              settled: keep == nil || settled.isEmpty ? nil : settled)
            print("live\t\(count)\t\(preview.text())")
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
            PreferencesPanel.shared.show()
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
    PreferencesPanel.shared.show()
}
if CommandLine.arguments.contains("--preferences") {
    PreferencesPanel.shared.show()
}
withExtendedLifetime((server, candidatePanel)) { app.run() }
