import Cocoa
import Carbon
import InputMethodKit
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
    private var pinnedPick: String?
    private let missingRange = NSRange(location: NSNotFound, length: 0)

    override func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool {
        guard let client = sender as? IMKTextInput else { return false }
        lastClient = client
        activeController = self
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(flags))
        // Key trace for routing diagnosis (codes only, never text content).
        Runtime.debugLog("key=\(keyCode) flags=\(flags) comp=\(composition.isEmpty ? 0 : 1) sel=\(selected) n=\(candidates.count)")
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
                composition.clear()
                candidates = []
                pinnedPick = nil
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
            if candidates.count > 1 {
                selected = (selected + (keyCode == 125 ? 1 : candidates.count - 1)) % candidates.count
                pinnedPick = candidates[selected].text
                mark(previewText, client)
                syncPanel(client)
                return true
            }
            commit(client)
            return false
        }
        if keyCode == 123 || keyCode == 124 { // Left/Right step when picking
            guard !composition.isEmpty else { return false }
            if candidates.count > 1 {
                selected = (selected + (keyCode == 124 ? 1 : candidates.count - 1)) % candidates.count
                pinnedPick = candidates[selected].text
                mark(previewText, client)
                syncPanel(client)
                return true
            }
            commit(client)
            return false
        }
        if keyCode == 53 {
            guard !composition.isEmpty else { return false }
            composition.clear()
            candidates = []
            pinnedPick = nil
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
            commit(client)
            return true
        }
        if keyCode == 48 && !composition.isEmpty {
            if candidates.count > 1 {
                // Tab steps forward, Shift+Tab steps back (Tab reliably
                // reaches the IME; arrows are often eaten by the client app
                // or the panel before inputText ever runs).
                let backward = modifiers.contains(.shift)
                selected = (selected + (backward ? candidates.count - 1 : 1)) % candidates.count
                pinnedPick = candidates[selected].text
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
        // stay phonetic or punctuate. The pick sticks across continued
        // typing (see refresh) and commits on Return/Space.
        // Order 1..8 on an ANSI keyboard.
        let digitOrder = [18, 19, 20, 21, 23, 22, 26, 28]
        if modifiers.contains(.shift), !modifiers.contains(.command),
           !modifiers.contains(.control), !modifiers.contains(.option),
           !english, !composition.isEmpty, candidates.count > 1,
           let pick = digitOrder.firstIndex(of: keyCode), pick < candidates.count {
            selected = pick
            pinnedPick = candidates[selected].text
            mark(previewText, client)
            syncPanel(client)
            return true
        }
        // CJK punctuation joins the running composition (no commit — mixed
        // spans commit once at the end). Checked before the generic modifier
        // passthrough and the phonetic path. Cmd shortcuts are never
        // hijacked: the table only matches listed combos and Cmd is excluded.
        if !modifiers.contains(.command),
           let punct = Punctuation.output(keyCode: keyCode,
                                          shift: modifiers.contains(.shift),
                                          ctrl: modifiers.contains(.control)) {
            selected = 0
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
                // Space is a boundary, never a commit: tone mark after
                // pending keys, literal separator otherwise. An empty
                // composition passes the space straight through.
                guard !composition.isEmpty else {
                    client.insertText(" ", replacementRange: missingRange)
                    return true
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
    private func refresh(_ client: IMKTextInput) {
        // Preview converts terminated runs (punctuation passes through in
        // place); the trailing pending run stays raw Bopomofo until commit.
        // Pinned pick survives continued typing: exact match first, then the
        // first candidate extending it. Fresh evidence that matches neither
        // clears the pin (top-1 floats again).
        let previous = candidates.map(\.text)
        candidates = Runtime.decoder.decodeSegments(composition.segments, pendingKeys: [])
        // Pinned pick survives continued typing: exact match first, then the
        // first candidate extending it. Fresh evidence that matches neither
        // clears the pin (top-1 floats again).
        if let pin = pinnedPick, !pin.isEmpty {
            if let exact = candidates.firstIndex(where: { $0.text == pin }) {
                selected = exact
            } else if let extended = candidates.firstIndex(where: { $0.text.hasPrefix(pin) }) {
                selected = extended
            } else {
                selected = 0
                pinnedPick = nil
            }
        } else if candidates.map(\.text) != previous || !candidates.indices.contains(selected) {
            selected = 0
        }
        syncPanel(client)
        mark(previewText, client)
    }
    /// Push our truth to the panel (highlight included — single owner, no
    /// echo loop possible since the panel never calls back).
    private func syncPanel(_ client: IMKTextInput) {
        if candidates.count > 1 {
            candidatePanel.update(candidates: candidates.map(\.text),
                                  selected: selected,
                                  anchor: caretAnchor(client))
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
        guard candidates.indices.contains(index) else { return }
        selected = index
        pinnedPick = candidates[index].text
        if let client = lastClient {
            mark(previewText, client)
            syncPanel(client)
        }
    }
    private func mark(_ text: String, _ client: IMKTextInput) {
        client.setMarkedText(text, selectionRange: NSRange(location: text.utf16.count, length: 0),
                             replacementRange: missingRange)
    }
    private func commit(_ client: IMKTextInput) {
        guard !composition.isEmpty else { return }
        var text: String
        if composition.parsed.pending.isEmpty && candidates.indices.contains(selected) {
            text = candidates[selected].text
        } else {
            text = Runtime.decoder.decodeSegments(composition.segments,
                                                  pendingKeys: composition.parsed.pending).first?.text
                ?? composition.rawPhonetic
        }
        while text.last?.isWhitespace == true { text.removeLast() }
        guard !text.isEmpty else { return }
        client.insertText(text, replacementRange: missingRange)
        composition.clear()
        candidates = []
        pinnedPick = nil
        selected = 0
        latinMode = false
        candidatePanel.hidePanel()
    }
    override func composedString(_ sender: Any!) -> Any! { previewText }
    override func originalString(_ sender: Any!) -> NSAttributedString { NSAttributedString(string: composition.rawPhonetic) }
    override func commitComposition(_ sender: Any!) {
        if let client = sender as? IMKTextInput { commit(client) }
    }
    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        super.deactivateServer(sender)
    }
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--decode" {
    var composition = Composition()
    var latin = false
    for key in CommandLine.arguments[2] {
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
    let results = decoder.decodeSegments(composition.segments, pendingKeys: parsed.pending)
    print("entries=\(decoder.entryCount) load_ms=\(loaded.timeIntervalSince(started) * 1000) decode_ms=\(Date().timeIntervalSince(loaded) * 1000)")
    for candidate in results { print("\(candidate.text)\t\(candidate.score)\trepairs=\(candidate.repairs) unresolved=\(candidate.unresolved)") }
    exit(0)
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
withExtendedLifetime((server, candidatePanel)) { app.run() }
