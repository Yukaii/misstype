import Foundation
import MisstypeCore
import MisstypeZigBridge
import CMisstype

/// InputSession-compatible presentation adapter backed by the Zig C ABI.
final class ZigSessionAdapter {
    private let engine: ZigEngine
    private let handle: OpaquePointer
    private(set) var view = SessionView.empty

    init?(engine: ZigEngine) {
        guard let session = engine.makeSession() else { return nil }
        self.engine = engine
        self.handle = session
        refresh()
    }

    deinit { misstype_session_free(handle) }

    var latinActive: Bool { misstype_session_latin_active(handle) != 0 }
    var rawPhonetic: String {
        guard let text = misstype_session_raw_phonetic(handle) else { return "" }
        defer { misstype_string_free(text) }
        return String(cString: text)
    }

    func handle(_ event: KeyEvent) -> KeyResult {
        syncSettings()
        var result = event.withCEvent { cEvent in
            misstype_session_handle(handle, &cEvent)
        }
        let output = KeyResult(consumed: result.consumed != 0,
                               commit: takeString(&result.commit),
                               beep: result.beep != 0,
                               modeChanged: result.mode_changed != 0,
                               latinToggled: result.latin_toggled != 0)
        refresh()
        return output
    }

    func commit() -> String? {
        guard let text = misstype_session_commit(handle) else { refresh(); return nil }
        defer { misstype_string_free(text) }
        let result = String(cString: text)
        refresh()
        return result
    }

    func pick(at index: Int) { misstype_session_pick(handle, Int32(index)); refresh() }
    func resetModifierState() { misstype_session_reset_modifiers(handle) }

    private func syncSettings() {
        let settings = MisstypePrefs.sessionSettings
        let candidateKeys = settings.candidateKeys
        candidateKeys.withCString { keys in
            var value = misstype_settings(
                fuzzy_repair: settings.fuzzyRepair ? 1 : 0,
                tone_tolerance: settings.toneTolerance ? 1 : 0,
                user_learning: settings.userLearning ? 1 : 0,
                shift_toggle: settings.shiftToggle ? 1 : 0,
                candidate_keys: keys,
                auto_show_candidates: settings.autoShowCandidates ? 1 : 0,
                return_confirms_selection: settings.returnConfirmsSelection ? 1 : 0,
                mixed_english: settings.mixedEnglish ? 1 : 0,
                auto_commit_syllables: Int32(settings.autoCommitSyllables),
                page_size: Int32(settings.pageSize),
                cursor_candidates: Int32(settings.cursorCandidates.rawValue == "endingAt" ? 1 : settings.cursorCandidates.rawValue == "beginningAt" ? 2 : 0))
            engine.setSettings(value)
        }
        engine.setKeyBindings(settings.keyBindings.serialized)
    }

    private func refresh() {
        guard let pointer = misstype_session_view(handle) else { view = .empty; return }
        defer { misstype_view_free(pointer) }
        let c = pointer.pointee
        let candidates = strings(c.candidates, count: Int(c.candidate_count))
        let keys = strings(c.selection_keys, count: Int(c.selection_key_count))
        var segments: [Range<Int>] = []
        if let values = c.segments_utf16 {
            for index in 0..<Int(c.segment_count) {
                segments.append(Int(values[2 * index])..<Int(values[2 * index + 1]))
            }
        }
        let focus: Range<Int>? = c.focus_start_utf16 >= 0 && c.focus_end_utf16 >= c.focus_start_utf16
            ? Int(c.focus_start_utf16)..<Int(c.focus_end_utf16) : nil
        let mark: SessionView.Mark? = {
            guard c.mark_action != MISSTYPE_MARK_NONE.rawValue,
                  let text = c.mark_text, let reading = c.mark_reading else { return nil }
            let action: SessionView.Mark.Action
            switch c.mark_action {
            case MISSTYPE_MARK_ADD.rawValue: action = .add
            case MISSTYPE_MARK_REMOVE.rawValue: action = .remove
            case MISSTYPE_MARK_TOO_SHORT.rawValue: action = .tooShort
            case MISSTYPE_MARK_TOO_LONG.rawValue: action = .tooLong
            default: action = .unavailable
            }
            return SessionView.Mark(range: Int(c.mark_start_utf16)..<Int(c.mark_end_utf16),
                                    text: String(cString: text), reading: String(cString: reading), action: action)
        }()
        view = SessionView(preedit: c.preedit.map(String.init(cString:)) ?? "",
                           caret: Int(c.caret_utf16), candidates: candidates,
                           selected: Int(c.selected), selectionKeys: keys,
                           keysActive: c.keys_active != 0, showsCandidates: c.shows_candidates != 0,
                           mark: mark, pageSize: max(1, Int(c.page_size)), segments: segments, focus: focus)
    }

    private func strings(_ values: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, count: Int) -> [String] {
        guard let values else { return [] }
        return (0..<count).compactMap { values[$0].map(String.init(cString:)) }
    }

    private func takeString(_ pointer: inout UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { misstype_string_free(pointer) }
        return String(cString: pointer)
    }
}

private extension KeyEvent {
    func withCEvent<T>(_ body: (inout misstype_key_event) -> T) -> T {
        let label: String
        if case .character(let value) = key { label = value } else { label = "" }
        return label.withCString { labelPointer in
            (text ?? "").withCString { textPointer in
                var event = misstype_key_event(kind: cKind, label: labelPointer,
                                               text: text == nil ? nil : textPointer,
                                               modifiers: UInt32(modifiers.rawValue),
                                               is_release: phase == .release ? 1 : 0,
                                               native_code: Int32(nativeCode ?? -1),
                                               timestamp: timestamp ?? -1)
                return body(&event)
            }
        }
    }

    var cKind: misstype_key_kind {
        switch key {
        case .character: return MISSTYPE_KEY_CHARACTER
        case .space: return MISSTYPE_KEY_SPACE
        case .enter: return MISSTYPE_KEY_ENTER
        case .tab: return MISSTYPE_KEY_TAB
        case .backspace: return MISSTYPE_KEY_BACKSPACE
        case .forwardDelete: return MISSTYPE_KEY_FORWARD_DELETE
        case .escape: return MISSTYPE_KEY_ESCAPE
        case .left: return MISSTYPE_KEY_LEFT
        case .right: return MISSTYPE_KEY_RIGHT
        case .up: return MISSTYPE_KEY_UP
        case .down: return MISSTYPE_KEY_DOWN
        case .pageUp: return MISSTYPE_KEY_PAGE_UP
        case .pageDown: return MISSTYPE_KEY_PAGE_DOWN
        case .shift(.left): return MISSTYPE_KEY_SHIFT_LEFT
        case .shift(.right): return MISSTYPE_KEY_SHIFT_RIGHT
        case .modifier: return MISSTYPE_KEY_MODIFIER
        case .other: return MISSTYPE_KEY_OTHER
        }
    }
}
