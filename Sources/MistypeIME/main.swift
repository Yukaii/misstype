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
}

@objc(MistypeInputController)
final class MistypeInputController: IMKInputController {
    private var composition = Composition()
    private var english = false
    private var candidates: [SentenceCandidate] = []
    private var selected = 0
    private let missingRange = NSRange(location: NSNotFound, length: 0)

    override func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool {
        guard let client = sender as? IMKTextInput else { return false }
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(flags))
        if keyCode == 49 && modifiers.contains(.shift) {
            commit(client)
            english.toggle()
            return true
        }
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
            commit(client)
            return false
        }
        if english || modifiers.contains(.capsLock) { commit(client); return false }
        if keyCode == 51 {
            guard !composition.isEmpty else { return false }
            composition.backspace()
            refresh(client)
            return true
        }
        if keyCode == 53 {
            guard !composition.isEmpty else { return false }
            composition.clear()
            candidates = []
            mark("", client)
            return true
        }
        if keyCode == 36 || keyCode == 76 {
            guard !composition.isEmpty else { return false }
            commit(client)
            return true
        }
        if keyCode == 48 && !composition.isEmpty {
            if candidates.count > 1 {
                selected = (selected + 1) % candidates.count
                mark(previewText, client)
            }
            return true
        }
        if modifiers.contains(.shift) { commit(client); return false }
        if let key = ZhuyinKeyboard.labels[keyCode] {
            if key == " " && composition.parsed.pending.isEmpty {
                guard !composition.isEmpty else { return false }
                commit(client)
                return true
            }
            if composition.append(key) { refresh(client); return true }
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
        candidates = Runtime.decoder.decode(composition.syllables(finishing: false))
        selected = 0
        mark(previewText, client)
    }
    private func mark(_ text: String, _ client: IMKTextInput) {
        client.setMarkedText(text, selectionRange: NSRange(location: text.utf16.count, length: 0),
                             replacementRange: missingRange)
    }
    private func commit(_ client: IMKTextInput) {
        guard !composition.isEmpty else { return }
        let text: String
        if composition.parsed.pending.isEmpty && candidates.indices.contains(selected) {
            text = candidates[selected].text
        } else {
            text = Runtime.decoder.decode(composition.syllables(finishing: true)).first?.text
                ?? composition.rawPhonetic
        }
        client.insertText(text, replacementRange: missingRange)
        composition.clear()
        candidates = []
        selected = 0
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
    for key in CommandLine.arguments[2] { _ = composition.append(String(key)) }
    let started = Date()
    let decoder = Runtime.decoder
    let loaded = Date()
    let results = decoder.decode(composition.syllables(finishing: true))
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
withExtendedLifetime(server) { app.run() }
