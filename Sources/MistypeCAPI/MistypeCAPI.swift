import Foundation
import MistypeCore
import CMistype

// MARK: - Handle management

/// The engine reads settings through this box on every call, so
/// `mistype_engine_set_settings` takes effect immediately.
private final class SettingsBox {
    var value = SessionSettings()
}

private final class EngineHandle {
    let engine: InputEngine
    let settings: SettingsBox
    init(engine: InputEngine, settings: SettingsBox) {
        self.engine = engine
        self.settings = settings
    }
}

private final class SessionHandle {
    let session: InputSession
    init(session: InputSession) {
        self.session = session
    }
}

private func retain(_ handle: EngineHandle) -> OpaquePointer {
    return OpaquePointer(Unmanaged.passRetained(handle).toOpaque())
}

private func retain(_ handle: SessionHandle) -> OpaquePointer {
    return OpaquePointer(Unmanaged.passRetained(handle).toOpaque())
}

private func releaseEngine(_ ptr: OpaquePointer) {
    Unmanaged<EngineHandle>.fromOpaque(UnsafeRawPointer(ptr)).release()
}

private func releaseSession(_ ptr: OpaquePointer) {
    Unmanaged<SessionHandle>.fromOpaque(UnsafeRawPointer(ptr)).release()
}

private func getEngine(_ ptr: OpaquePointer?) -> EngineHandle? {
    guard let ptr = ptr else { return nil }
    return Unmanaged<EngineHandle>.fromOpaque(UnsafeRawPointer(ptr)).takeUnretainedValue()
}

private func getSession(_ ptr: OpaquePointer?) -> SessionHandle? {
    guard let ptr = ptr else { return nil }
    return Unmanaged<SessionHandle>.fromOpaque(UnsafeRawPointer(ptr)).takeUnretainedValue()
}

// MARK: - Conversion helpers

private func toMistypeKey(_ key: KeyEvent.Key) -> mistype_key_kind {
    switch key {
    case .character: return MISTYPE_KEY_CHARACTER
    case .space: return MISTYPE_KEY_SPACE
    case .enter: return MISTYPE_KEY_ENTER
    case .tab: return MISTYPE_KEY_TAB
    case .backspace: return MISTYPE_KEY_BACKSPACE
    case .forwardDelete: return MISTYPE_KEY_FORWARD_DELETE
    case .escape: return MISTYPE_KEY_ESCAPE
    case .left: return MISTYPE_KEY_LEFT
    case .right: return MISTYPE_KEY_RIGHT
    case .up: return MISTYPE_KEY_UP
    case .down: return MISTYPE_KEY_DOWN
    case .pageUp: return MISTYPE_KEY_PAGE_UP
    case .pageDown: return MISTYPE_KEY_PAGE_DOWN
    case .shift(.left): return MISTYPE_KEY_SHIFT_LEFT
    case .shift(.right): return MISTYPE_KEY_SHIFT_RIGHT
    case .modifier: return MISTYPE_KEY_MODIFIER
    case .other: return MISTYPE_KEY_OTHER
    }
}

private func toMistypeModifiers(_ modifiers: KeyEvent.Modifiers) -> UInt32 {
    var result: UInt32 = 0
    if modifiers.contains(.shift) { result |= UInt32(MISTYPE_MOD_SHIFT) }
    if modifiers.contains(.control) { result |= UInt32(MISTYPE_MOD_CONTROL) }
    if modifiers.contains(.option) { result |= UInt32(MISTYPE_MOD_ALT) }
    if modifiers.contains(.command) { result |= UInt32(MISTYPE_MOD_SUPER) }
    if modifiers.contains(.capsLock) { result |= UInt32(MISTYPE_MOD_CAPS_LOCK) }
    return result
}

private func fromMistypeModifiers(_ modifiers: UInt32) -> KeyEvent.Modifiers {
    var result = KeyEvent.Modifiers()
    if modifiers & UInt32(MISTYPE_MOD_SHIFT) != 0 { result.insert(.shift) }
    if modifiers & UInt32(MISTYPE_MOD_CONTROL) != 0 { result.insert(.control) }
    if modifiers & UInt32(MISTYPE_MOD_ALT) != 0 { result.insert(.option) }
    if modifiers & UInt32(MISTYPE_MOD_SUPER) != 0 { result.insert(.command) }
    if modifiers & UInt32(MISTYPE_MOD_CAPS_LOCK) != 0 { result.insert(.capsLock) }
    return result
}

private func keyEventFromC(_ event: mistype_key_event) -> KeyEvent {
    let key: KeyEvent.Key
    switch event.kind {
    case MISTYPE_KEY_CHARACTER:
        if let label = event.label {
            key = .character(String(cString: label))
        } else {
            key = .other
        }
    case MISTYPE_KEY_SPACE: key = .space
    case MISTYPE_KEY_ENTER: key = .enter
    case MISTYPE_KEY_TAB: key = .tab
    case MISTYPE_KEY_BACKSPACE: key = .backspace
    case MISTYPE_KEY_FORWARD_DELETE: key = .forwardDelete
    case MISTYPE_KEY_ESCAPE: key = .escape
    case MISTYPE_KEY_LEFT: key = .left
    case MISTYPE_KEY_RIGHT: key = .right
    case MISTYPE_KEY_UP: key = .up
    case MISTYPE_KEY_DOWN: key = .down
    case MISTYPE_KEY_PAGE_UP: key = .pageUp
    case MISTYPE_KEY_PAGE_DOWN: key = .pageDown
    case MISTYPE_KEY_SHIFT_LEFT: key = .shift(.left)
    case MISTYPE_KEY_SHIFT_RIGHT: key = .shift(.right)
    case MISTYPE_KEY_MODIFIER: key = .modifier
    case MISTYPE_KEY_OTHER: key = .other
    default: key = .other
    }
    let phase: KeyEvent.Phase = event.is_release != 0 ? .release : .press
    let modifiers = fromMistypeModifiers(event.modifiers)
    let text = event.text.map { String(cString: $0) }
    let nativeCode = event.native_code >= 0 ? Int(event.native_code) : nil
    let timestamp = event.timestamp >= 0 ? event.timestamp : nil
    return KeyEvent(key, phase: phase, modifiers: modifiers, text: text, nativeCode: nativeCode, timestamp: timestamp)
}

private func strdupSwift(_ string: String) -> UnsafeMutablePointer<CChar> {
    let utf8 = string.utf8
    let ptr = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count + 1)
    var i = 0
    for codeUnit in utf8 {
        ptr[i] = CChar(bitPattern: codeUnit)
        i += 1
    }
    ptr[i] = 0
    return ptr
}

private func strdupOptional(_ string: String?) -> UnsafeMutablePointer<CChar>? {
    guard let string = string else { return nil }
    return strdupSwift(string)
}

private func freeString(_ ptr: UnsafeMutablePointer<CChar>?) {
    ptr?.deallocate()
}

private func copyStringArray(_ array: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
    let ptr = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: array.count)
    for (i, s) in array.enumerated() {
        ptr[i] = strdupSwift(s)
    }
    return ptr
}

private func freeStringArray(_ ptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, count: Int) {
    guard let ptr = ptr else { return }
    for i in 0..<count {
        freeString(ptr[i])
    }
    ptr.deallocate()
}

private func caretBytes(_ preedit: String, caretUTF16: Int) -> Int {
    let utf16 = preedit.utf16
    let end = utf16.index(utf16.startIndex, offsetBy: min(max(caretUTF16, 0), utf16.count))
    return preedit.utf8.distance(from: preedit.utf8.startIndex, to: end)
}

/// Key labels are handed out as static C strings (the header promises callers
/// never free them), so each distinct label is duplicated exactly once.
private let staticLabels: [String: UnsafePointer<CChar>] = {
    var table: [String: UnsafePointer<CChar>] = [:]
    for label in Set(EvdevKeyCode.labels.values).union(MacKeyCode.labels.values) {
        table[label] = UnsafePointer(strdup(label))
    }
    return table
}()

// MARK: - C ABI implementations

@_cdecl("mistype_abi_version")
public func mistype_abi_version() -> Int32 {
    return MISTYPE_ABI_VERSION
}

@_cdecl("mistype_settings_default")
public func mistype_settings_default() -> mistype_settings {
    return mistype_settings(
        fuzzy_repair: 1,
        tone_tolerance: 1,
        user_learning: 1,
        shift_toggle: 1,
        candidate_keys: nil,
        auto_commit_syllables: 24
    )
}

@_cdecl("mistype_engine_new")
public func mistype_engine_new(
    _ resource_dir: UnsafePointer<CChar>?,
    _ user_lexicon_path: UnsafePointer<CChar>?
) -> OpaquePointer? {
    guard let resourceDirPtr = resource_dir else { return nil }
    let resourceDir = String(cString: resourceDirPtr)
    
    let lexiconURL = URL(fileURLWithPath: resourceDir).appendingPathComponent("lexicon.tsv")
    guard FileManager.default.fileExists(atPath: lexiconURL.path) else { return nil }
    
    guard let decoder = LexiconLoader.load(resourceDirectory: URL(fileURLWithPath: resourceDir)) else { return nil }
    let settings = SettingsBox()
    let engine = InputEngine(decoder: decoder, settings: { settings.value })
    
    let userLexiconURL: URL?
    if let pathPtr = user_lexicon_path {
        let path = String(cString: pathPtr)
        if path.isEmpty {
            userLexiconURL = nil // memory only
        } else {
            userLexiconURL = URL(fileURLWithPath: path)
        }
    } else {
        userLexiconURL = UserLexicon.defaultURL
    }
    
    if let url = userLexiconURL {
        engine.userLexicon = UserLexicon.load(from: url)
        engine.userLexiconURL = url
    } else {
        engine.userLexicon = UserLexicon()
        engine.userLexiconURL = nil
    }
    
    let handle = EngineHandle(engine: engine, settings: settings)
    return retain(handle)
}

@_cdecl("mistype_engine_free")
public func mistype_engine_free(_ engine: OpaquePointer?) {
    if let engine = engine {
        releaseEngine(engine)
    }
}

@_cdecl("mistype_engine_set_settings")
public func mistype_engine_set_settings(
    _ engine: OpaquePointer?,
    _ settings: UnsafePointer<mistype_settings>?
) {
    guard let engine = engine, let settings = settings else { return }
    let handle = getEngine(engine)
    handle?.settings.value = SessionSettings(
        fuzzyRepair: settings.pointee.fuzzy_repair != 0,
        toneTolerance: settings.pointee.tone_tolerance != 0,
        candidateKeys: settings.pointee.candidate_keys.map { String(cString: $0) } ?? "asdfghjkl;",
        userLearning: settings.pointee.user_learning != 0,
        shiftToggle: settings.pointee.shift_toggle != 0,
        autoCommitSyllables: max(0, Int(settings.pointee.auto_commit_syllables))
    )
}

@_cdecl("mistype_engine_is_english")
public func mistype_engine_is_english(_ engine: OpaquePointer?) -> Int32 {
    guard let engine = engine else { return 0 }
    let handle = getEngine(engine)
    return handle?.engine.english == true ? 1 : 0
}

@_cdecl("mistype_session_new")
public func mistype_session_new(_ engine: OpaquePointer?) -> OpaquePointer? {
    guard let engine = engine else { return nil }
    let handle = getEngine(engine)
    guard let engineHandle = handle else { return nil }
    let session = InputSession(engine: engineHandle.engine)
    return retain(SessionHandle(session: session))
}

@_cdecl("mistype_session_free")
public func mistype_session_free(_ session: OpaquePointer?) {
    if let session = session {
        releaseSession(session)
    }
}

@_cdecl("mistype_session_handle")
public func mistype_session_handle(
    _ session: OpaquePointer?,
    _ event: UnsafePointer<mistype_key_event>?
) -> mistype_key_result {
    var result = mistype_key_result(consumed: 0, commit: nil, beep: 0, mode_changed: 0)
    guard let session = session, let event = event else { return result }
    let handle = getSession(session)
    guard let sessionHandle = handle else { return result }
    
    let keyEvent = keyEventFromC(event.pointee)
    let keyResult = sessionHandle.session.handle(keyEvent)
    
    result.consumed = keyResult.consumed ? 1 : 0
    result.commit = strdupOptional(keyResult.commit)
    result.beep = keyResult.beep ? 1 : 0
    result.mode_changed = keyResult.modeChanged ? 1 : 0
    return result
}

@_cdecl("mistype_session_commit")
public func mistype_session_commit(_ session: OpaquePointer?) -> UnsafeMutablePointer<CChar>? {
    guard let session = session else { return nil }
    let handle = getSession(session)
    guard let sessionHandle = handle else { return nil }
    let committed = sessionHandle.session.commit()
    return strdupOptional(committed)
}

@_cdecl("mistype_session_pick")
public func mistype_session_pick(_ session: OpaquePointer?, _ index: Int32) {
    guard let session = session else { return }
    let handle = getSession(session)
    handle?.session.pick(at: Int(index))
}

@_cdecl("mistype_session_reset_modifiers")
public func mistype_session_reset_modifiers(_ session: OpaquePointer?) {
    guard let session = session else { return }
    let handle = getSession(session)
    handle?.session.resetModifierState()
}

@_cdecl("mistype_session_raw_phonetic")
public func mistype_session_raw_phonetic(_ session: OpaquePointer?) -> UnsafeMutablePointer<CChar>? {
    guard let session = session else { return nil }
    let handle = getSession(session)
    return strdupOptional(handle?.session.rawPhonetic)
}

@_cdecl("mistype_session_view")
public func mistype_session_view(_ session: OpaquePointer?) -> UnsafeMutablePointer<mistype_view>? {
    guard let session = session else { return nil }
    let handle = getSession(session)
    guard let sessionHandle = handle else { return nil }
    let view = sessionHandle.session.view
    
    let viewPtr = UnsafeMutablePointer<mistype_view>.allocate(capacity: 1)
    viewPtr.initialize(to: mistype_view(
        preedit: strdupSwift(view.preedit),
        caret_bytes: Int32(caretBytes(view.preedit, caretUTF16: view.caret)),
        caret_utf16: Int32(view.caret),
        candidates: copyStringArray(view.candidates),
        candidate_count: Int32(view.candidates.count),
        selected: Int32(view.selected),
        selection_keys: copyStringArray(view.selectionKeys),
        selection_key_count: Int32(view.selectionKeys.count),
        keys_active: view.keysActive ? 1 : 0,
        shows_candidates: view.showsCandidates ? 1 : 0
    ))
    return viewPtr
}

@_cdecl("mistype_key_from_evdev")
public func mistype_key_from_evdev(_ evdev_code: Int32, _ label: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> mistype_key_kind {
    let key = EvdevKeyCode.key(Int(evdev_code))
    if let labelPtr = label {
        switch key {
        case .character(let l):
            labelPtr.pointee = staticLabels[l]
        default:
            labelPtr.pointee = nil
        }
    }
    return toMistypeKey(key)
}

@_cdecl("mistype_key_from_character")
public func mistype_key_from_character(
    _ utf8: UnsafePointer<CChar>?,
    _ label: UnsafeMutablePointer<UnsafePointer<CChar>?>?,
    _ shifted: UnsafeMutablePointer<Int32>?
) -> mistype_key_kind {
    guard let utf8 = utf8 else { return MISTYPE_KEY_OTHER }
    let string = String(cString: utf8)
    guard string.count == 1, let ch = string.first else { return MISTYPE_KEY_OTHER }
    
    if let mapping = USLayout.key(forCharacter: ch) {
        if let labelPtr = label {
            switch mapping.key {
            case .character(let l):
                labelPtr.pointee = staticLabels[l]
            default:
                labelPtr.pointee = nil
            }
        }
        shifted?.pointee = mapping.shifted ? 1 : 0
        return toMistypeKey(mapping.key)
    }
    return MISTYPE_KEY_OTHER
}

@_cdecl("mistype_view_free")
public func mistype_view_free(_ view: UnsafeMutablePointer<mistype_view>?) {
    guard let view = view else { return }
    freeString(view.pointee.preedit)
    freeStringArray(view.pointee.candidates, count: Int(view.pointee.candidate_count))
    freeStringArray(view.pointee.selection_keys, count: Int(view.pointee.selection_key_count))
    view.deallocate()
}

@_cdecl("mistype_string_free")
public func mistype_string_free(_ string: UnsafeMutablePointer<CChar>?) {
    freeString(string)
}