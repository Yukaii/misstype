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
        return LexiconDecoder(tsv: data)
    }()
    /// Explicit-opt-in user overlay, loaded once at startup and reloaded
    /// when the preference flips on. Gated per keystroke by
    /// MistypePrefs.userLearning — off means nil, i.e. byte-identical decode.
    static var userLexicon = UserLexicon.load()
    static var activeUserLexicon: UserLexicon? {
        MistypePrefs.userLearning ? userLexicon : nil
    }
    /// Jev gateway policy, read live per keystroke like the other prefs.
    /// Default off: `canAttempt == false` means decode stays byte-identical
    /// to the offline path. When the user explicitly enables it AND provides
    /// a key, the adapter only logs the gated intent (presence, never the
    /// key or text) — no remote call ships until the triage battery verdict
    /// (DO NOT WIRE) is overturned by fresh-seed evidence.
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

@objc(MistypeInputController)
final class MistypeInputController: IMKInputController {
    private var composition = Composition()
    private var english = false
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
    /// Focused-span options (nil = whole-span list). Picking pins the
    /// segment into sessionPins and advances the cursor; pins hold until
    /// commit/clear/Escape and never touch disk.
    private var segmentTexts: [String]?
    private var segmentSelected = 0
    private var segmentSpan: Range<Int>?
    private var segmentChars: Range<Int>?
    private var sessionPins = UserLexicon()
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

    override func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool {
        guard let client = sender as? IMKTextInput else { return false }
        lastClient = client
        activeController = self
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(flags))
        // Key trace for routing diagnosis (codes only, never text content).
        Runtime.debugLog("key=\(keyCode) flags=\(flags) comp=\(composition.isEmpty ? 0 : 1) sel=\(selected) n=\(candidates.count) cur=\(cursor ?? -1) seg=\(segmentTexts == nil ? 0 : 1)")
        if keyCode == 49 && modifiers.contains(.shift) {
            commit(client)
            english.toggle()
            latinMode = false
            return true
        }
        if english || modifiers.contains(.capsLock) { commit(client); return false }
        // Latin mode ends on anything but letters, space (multi-word runs
        // stay latin: `hello world`), and the backtick toggle: tones,
        // punctuation, digits and commit keys resume Zhuyin.
        let latinLetter: Bool = {
            guard latinMode, !english,
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
        if keyCode == 123 || keyCode == 124 { // Left/Right: cursor first, paging fallback
            guard !composition.isEmpty else { return false }
            if keyCode == 123, moveCursorBack(client) { return true }
            if keyCode == 124, moveCursorForward(client) { return true }
            let pages = (candidates.count + 7) / 8
            if pages > 1 {
                let row = selected % 8
                let newPage = (selected / 8 + (keyCode == 124 ? 1 : pages - 1)) % pages
                var index = newPage * 8 + row
                if index >= candidates.count { index = candidates.count - 1 }
                selected = index
                pinnedPick = candidates[selected].text
                explicitPick = true
                mark(previewText, client)
                syncPanel(client)
                return true
            }
            if candidates.count > 1 {
                selected = (selected + (keyCode == 124 ? 1 : candidates.count - 1)) % candidates.count
                pinnedPick = candidates[selected].text
                explicitPick = true
                mark(previewText, client)
                syncPanel(client)
                return true
            }
            commit(client)
            return false
        }
        if keyCode == 53 {
            guard !composition.isEmpty else { return false }
            _ = nextJevID()
            composition.clear()
            candidates = []
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
            if let texts = segmentTexts, texts.indices.contains(segmentSelected) {
                // Focused Return pins the highlighted segment, re-decodes so
                // top-1 honors it, then commits everything at once.
                pinAdvance(client, texts[segmentSelected])
                selected = 0
            }
            commit(client)
            return true
        }
        if keyCode == 48 && !composition.isEmpty {
            if let texts = segmentTexts, texts.indices.contains(segmentSelected) {
                // Focused Tab pins without committing: Left…Tab,Tab,Return
                // fixes two mid-sentence words and sends the sentence.
                pinAdvance(client, texts[segmentSelected])
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
                mark(previewText, client)
                syncPanel(client)
            }
            return true
        }
        // Backtick toggles latin-run mode (no modifiers, either language
        // mode off): following letters append verbatim. Swallowed silently —
        // the letters themselves are the feedback. Shift+` stays ASCII ~.
        if keyCode == 50 && !modifiers.contains(.shift) && !modifiers.contains(.command)
            && !modifiers.contains(.control) && !modifiers.contains(.option) && !english {
            latinMode.toggle()
            Runtime.debugLog("latin=\(latinMode ? 1 : 0)")
            return true
        }
        // Shift+digit selects a candidate: digits are Zhuyin keys, so this
        // runs only while the window is up (candidates>1); otherwise digits
        // stay phonetic or punctuate. Shift+1 is always ！ (candidate #1
        // needs no shortcut — it is the default), so selection starts at 2.
        // Order 2..8 on an ANSI keyboard.
        let digitOrder = [19, 20, 21, 23, 22, 26, 28]
        if modifiers.contains(.shift), !modifiers.contains(.command),
           !modifiers.contains(.control), !modifiers.contains(.option),
           !english, !composition.isEmpty,
           candidates.count > 1 || (segmentTexts?.count ?? 0) > 1,
           let digit = digitOrder.firstIndex(of: keyCode) {
            // Digits address the visible page (panel shows 8 of up to 16);
            // out-of-range digits fall through to punct/phonetic below.
            // Focused mode tries the segment list first, then the whole
            // list, so nothing silently stops working at the boundary.
            if let texts = segmentTexts {
                let global = (segmentSelected / 8) * 8 + digit + 1
                if global < texts.count {
                    pinAdvance(client, texts[global])
                    return true
                }
            }
            if segmentTexts == nil {
                let global = (selected / 8) * 8 + digit + 1
                if global < candidates.count {
                    selected = global
                    pinnedPick = candidates[selected].text
                    explicitPick = true
                    mark(previewText, client)
                    syncPanel(client)
                    return true
                }
            }
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
        return converted + composition.pendingText
    }
    /// Caret shared by marked text and the panel header: focused word start,
    /// else after the last unit. UTF-16 offsets throughout.
    private var caretOffset: Int {
        let len = previewText.utf16.count
        if let focused = segmentChars?.lowerBound { return min(focused, len) }
        return len
    }
    /// Safely extracts preceding text context and bundle identifier from the client.
    private func currentContext(_ client: IMKTextInput) -> ClientContext {
        let adapter = IMKTextInputContextAdapter(client)
        return SurroundingContext.extract(from: adapter)
    }
    private func refresh(_ client: IMKTextInput, keepCursor: Bool = false) {
        // Preview converts terminated runs (punctuation passes through in
        // place); the trailing pending run stays raw Bopomofo until commit.
        let previous = candidates.map(\.text)
        // Jev gate threads through every decode entry point but changes
        // nothing while off (the default): the offline decode below is the
        // single source of candidates. Presence-only logging keeps remote
        // intent observable per repo policy without leaking key or text.
        // gated intent only: no remote call (battery verdict DO NOT WIRE).
        Runtime.logJevGate()
        let context = currentContext(client)
        Runtime.debugLog("context chars=\(context.precedingText.count) app=\(context.bundleIdentifier ?? "none")")
        candidates = Runtime.decoder.decodeSegments(composition.segments, pendingKeys: [], fuzzy: MistypePrefs.fuzzyRepair, toneTolerance: MistypePrefs.toneTolerance, userLexicon: Runtime.activeUserLexicon, locked: sessionPins.isEmpty ? nil : sessionPins)
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
        }
        if cursor != nil {
            focusSegment()
        } else {
            clearSegment()
        }
        syncPanel(client)
        mark(previewText, client)
        scheduleJevEvaluation(context: context)
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
            pinAdvance(client, texts[index])
            return
        }
        guard candidates.indices.contains(index) else { return }
        selected = index
        pinnedPick = candidates[index].text
        explicitPick = true
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
    private func scheduleJevEvaluation(context: ClientContext) {
        let requestID = nextJevID()
        let config = MistypePrefs.jevConfig
        guard config.canAttempt,
              !composition.isEmpty,
              candidates.count > 1,
              pinnedPick == nil,
              !explicitPick,
              segmentTexts == nil else { return }

        let rawKeys = composition.rawKeys.joined()
        let evidence: [JevState.Evidence] = composition.segments.compactMap { seg in
            if case .syllable(let s) = seg {
                return JevState.Evidence(base: s.base, tone: s.tone)
            }
            return nil
        }
        let candTuples = Array(candidates.prefix(8)).map {
            (text: $0.text, score: $0.score, repairs: $0.repairs, unresolved: $0.unresolved)
        }
        let userCtx = context.precedingText

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

    private func commit(_ client: IMKTextInput) {
        guard !composition.isEmpty else { return }
        var text: String
        // Learning-grade commit: the user saw exactly candidates[selected]
        // (no pending tail re-decode) and explicitly picked it. Anything
        // else — pending re-decode, separator pinning, raw fallback — never
        // trains, so routine typing leaves the overlay untouched.
        let learnable = composition.parsed.pending.isEmpty
            && candidates.indices.contains(selected)
        if learnable {
            text = candidates[selected].text
        } else {
            // Offline recompute: the Jev gate stays closed here too (same
            // policy as refresh — explicit enable + key, else offline).
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
        if MistypePrefs.userLearning && explicitPick && learnable
            && candidates[selected].unresolved == 0,
            let key = composition.learnableKey {
            Runtime.userLexicon.record(key: key, text: text)
            Runtime.userLexicon.save()
        }
        client.insertText(text, replacementRange: missingRange)
        _ = nextJevID()
        composition.clear()
        candidates = []
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
        let syllables: [Syllable] // rebuilt converted list
        let top: SentenceCandidate
    }
    /// Rebuild validation: the cursor trusts a focused span only when the
    /// locally rebuilt syllable list has exactly the length the top
    /// candidate's alignment covers (pure single run, clean top-1). Fused
    /// tone runs and ambiguous re-segmentations fall back to whole-span
    /// behavior instead of pointing at the wrong word combustion.
    private func focusFrame() -> FocusFrame? {
        guard composition.learnableKey != nil,
              candidates.indices.contains(selected) else { return nil }
        let top = candidates[selected]
        // No repairs gate: alignment is filled on every path and the
        // word-in-options check below already guards correctness — repaired
        // (typo'd) words are exactly what the cursor is for. Unresolved
        // (raw fallback) spans stay out: nothing to offer there.
        guard top.unresolved == 0,
              let end = top.alignment.last?.syllables.upperBound, end > 0 else { return nil }
        let parsed = composition.parsed
        var rebuilt = parsed.complete
        if !parsed.pending.isEmpty {
            guard let first = Runtime.decoder.segmentKeys(
                parsed.pending, fuzzy: MistypePrefs.fuzzyRepair,
                toneTolerance: MistypePrefs.toneTolerance).first,
                !first.isEmpty else { return nil }
            rebuilt += first
        }
        guard rebuilt.count == end else { return nil }
        return FocusFrame(syllables: rebuilt, top: top)
    }
    private func spanText(_ text: String, _ chars: Range<Int>) -> String? {
        let units = Array(text.utf16)
        guard chars.lowerBound >= 0, chars.upperBound <= units.count else { return nil }
        return String(decoding: units[chars], as: UTF16.self)
    }
    private func clearSegment() {
        segmentTexts = nil
        segmentSelected = 0
        segmentSpan = nil
        segmentChars = nil
    }
    /// Point the cursor at its span: fill the segment list, verify the
    /// aligned word is among the options. Drops back to end on any mismatch.
    /// Outcomes are traced by code (numbers only): ok, noframe, noword.
    private func focusSegment() {
        clearSegment()
        guard let c = cursor, let frame = focusFrame(),
              let span = frame.top.alignment.first(where: { $0.syllables.contains(c) }) else {
            Runtime.debugLog("focus noframe")
            cursor = nil
            return
        }
        let options = Runtime.decoder.segmentOptions(
            frame.syllables, span: span.syllables, fuzzy: MistypePrefs.fuzzyRepair,
            toneTolerance: MistypePrefs.toneTolerance)
        guard let word = spanText(frame.top.text, span.chars),
              let current = options.firstIndex(where: { $0.text == word }) else {
            Runtime.debugLog("focus noword")
            cursor = nil
            return
        }
        Runtime.debugLog("focus ok s=\(span.syllables.lowerBound)-\(span.syllables.upperBound) c=\(span.chars.lowerBound)-\(span.chars.upperBound)")
        segmentTexts = options.map(\.text)
        segmentSelected = current
        segmentSpan = span.syllables
        segmentChars = span.chars
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
    /// Pin the focused segment: session-scoped decisive bonus (never disk).
    /// Whole-text pin is cleared so the two never fight; the pick counts as
    /// explicit for user-phrase learning at commit.
    private func pinSegment(_ text: String) {
        guard let span = segmentSpan, let frame = focusFrame(),
              span.upperBound <= frame.syllables.count else { return }
        let key = UserLexicon.key(for: Array(frame.syllables[span]))
        sessionPins.entries[key] = [text: UserLexicon.Record(
            count: 1, updatedAt: Date().timeIntervalSince1970)]
        pinnedPick = nil
        explicitPick = true
    }
    private func pinAdvance(_ client: IMKTextInput, _ text: String) {
        pinSegment(text)
        cursor = segmentSpan?.upperBound
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
        Runtime.debugLog("[ime] activateServer")
    }

    override func deactivateServer(_ sender: Any!) {
        Runtime.debugLog("[ime] deactivateServer")
        commitComposition(sender)
        super.deactivateServer(sender)
    }
}

if let decodeIndex = CommandLine.arguments.firstIndex(of: "--decode"),
   decodeIndex + 1 < CommandLine.arguments.count {
    var composition = Composition()
    var latin = false
    for key in CommandLine.arguments[decodeIndex + 1] {
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

let app = NSApplication.shared
_ = Runtime.decoder
guard NSClassFromString("MistypeInputController") != nil,
      let bundleID = Bundle.main.bundleIdentifier,
      let server = IMKServer(name: "MistypeServer", bundleIdentifier: bundleID) else {
    NSLog("Mistype: InputMethodKit initialization failed")
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
DistributedNotificationCenter.default().addObserver(
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
