import Cocoa
import MisstypeMacKit

extension KeyAction {
    var title: String {
        switch self {
        case .toggleEnglish: return L("Switch Chinese/English")
        case .nextCandidate: return L("Next candidate")
        case .previousCandidate: return L("Previous candidate")
        case .nextPage: return L("Next page (also = while selecting)")
        case .previousPage: return L("Previous page (also - while selecting)")
        case .cursorBack: return L("Syllable cursor back")
        case .cursorForward: return L("Syllable cursor forward")
        case .markBack: return L("Mark a phrase backward")
        case .markForward: return L("Mark a phrase forward")
        case .commit: return L("Commit")
        case .commitRaw: return L("Commit the keys as typed")
        case .cancel: return L("Leave selection; press again to clear")
        case .latinRun: return L("Start or end an English run")
        }
    }
}

extension KeyChord {
    /// macOS notation: ⌃⌥⇧⌘ then the key.
    var symbol: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        switch key {
        case .character(let label): out += label.uppercased()
        case .space: out += "Space"
        case .enter: out += "⏎"
        case .tab: out += "⇥"
        case .escape: out += "Esc"
        case .left: out += "←"
        case .right: out += "→"
        case .up: out += "↑"
        case .down: out += "↓"
        case .pageUp: out += "Page Up"
        case .pageDown: out += "Page Down"
        default: out += "?"
        }
        return out
    }

    /// The chord a key-down event types, nil for keys a binding cannot use.
    init?(event: NSEvent) {
        var modifiers: KeyEvent.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self.init(MacKeyCode.key(Int(event.keyCode)), modifiers)
        guard isBindable else { return nil }
    }
}

