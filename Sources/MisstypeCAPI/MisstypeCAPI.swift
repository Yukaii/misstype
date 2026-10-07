import Foundation
import MisstypeCore
import CMisstype

// MARK: - Handle management

/// The engine reads settings through this box on every call, so
/// `misstype_engine_set_settings` takes effect immediately.
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

private func toMisstypeKey(_ key: KeyEvent.Key) -> misstype_key_kind {
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

private func toMisstypeModifiers(_ modifiers: KeyEvent.Modifiers) -> UInt32 {
    var result: UInt32 = 0
    if modifiers.contains(.shift) { result |= UInt32(MISSTYPE_MOD_SHIFT) }
    if modifiers.contains(.control) { result |= UInt32(MISSTYPE_MOD_CONTROL) }
    if modifiers.contains(.option) { result |= UInt32(MISSTYPE_MOD_ALT) }
    if modifiers.contains(.command) { result |= UInt32(MISSTYPE_MOD_SUPER) }
    if modifiers.contains(.capsLock) { result |= UInt32(MISSTYPE_MOD_CAPS_LOCK) }
    return result
}

private func fromMisstypeModifiers(_ modifiers: UInt32) -> KeyEvent.Modifiers {
    var result = KeyEvent.Modifiers()
    if modifiers & UInt32(MISSTYPE_MOD_SHIFT) != 0 { result.insert(.shift) }
    if modifiers & UInt32(MISSTYPE_MOD_CONTROL) != 0 { result.insert(.control) }
    if modifiers & UInt32(MISSTYPE_MOD_ALT) != 0 { result.insert(.option) }
    if modifiers & UInt32(MISSTYPE_MOD_SUPER) != 0 { result.insert(.command) }
    if modifiers & UInt32(MISSTYPE_MOD_CAPS_LOCK) != 0 { result.insert(.capsLock) }
    return result
}

private func keyEventFromC(_ event: misstype_key_event) -> KeyEvent {
    let key: KeyEvent.Key
    switch event.kind {
    case MISSTYPE_KEY_CHARACTER:
        if let label = event.label {
            key = .character(String(cString: label))
        } else {
            key = .other
        }
    case MISSTYPE_KEY_SPACE: key = .space
    case MISSTYPE_KEY_ENTER: key = .enter
    case MISSTYPE_KEY_TAB: key = .tab
    case MISSTYPE_KEY_BACKSPACE: key = .backspace
    case MISSTYPE_KEY_FORWARD_DELETE: key = .forwardDelete
    case MISSTYPE_KEY_ESCAPE: key = .escape
    case MISSTYPE_KEY_LEFT: key = .left
    case MISSTYPE_KEY_RIGHT: key = .right
    case MISSTYPE_KEY_UP: key = .up
    case MISSTYPE_KEY_DOWN: key = .down
    case MISSTYPE_KEY_PAGE_UP: key = .pageUp
    case MISSTYPE_KEY_PAGE_DOWN: key = .pageDown
    case MISSTYPE_KEY_SHIFT_LEFT: key = .shift(.left)
    case MISSTYPE_KEY_SHIFT_RIGHT: key = .shift(.right)
    case MISSTYPE_KEY_MODIFIER: key = .modifier
    case MISSTYPE_KEY_OTHER: key = .other
    default: key = .other
    }
    let phase: KeyEvent.Phase = event.is_release != 0 ? .release : .press
    let modifiers = fromMisstypeModifiers(event.modifiers)
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

private func markAction(_ mark: SessionView.Mark?) -> Int32 {
    guard let mark else { return Int32(MISSTYPE_MARK_NONE.rawValue) }
    switch mark.action {
    case .add: return Int32(MISSTYPE_MARK_ADD.rawValue)
    case .remove: return Int32(MISSTYPE_MARK_REMOVE.rawValue)
    case .tooShort: return Int32(MISSTYPE_MARK_TOO_SHORT.rawValue)
    case .tooLong: return Int32(MISSTYPE_MARK_TOO_LONG.rawValue)
    case .unavailable: return Int32(MISSTYPE_MARK_UNAVAILABLE.rawValue)
    }
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

@_cdecl("misstype_abi_version")
public func misstype_abi_version() -> Int32 {
    return MISSTYPE_ABI_VERSION
}

@_cdecl("misstype_settings_default")
public func misstype_settings_default() -> misstype_settings {
    return misstype_settings(
        fuzzy_repair: 1,
        tone_tolerance: 1,
        user_learning: 1,
        shift_toggle: 1,
        candidate_keys: nil,
        auto_show_candidates: 1,
        return_confirms_selection: 0,
        mixed_english: 1,
        auto_commit_syllables: 24,
        page_size: Int32(SelectionKeys.defaultPageSize),
        cursor_candidates: Int32(MISSTYPE_CURSOR_COVERING.rawValue)
    )
}

@_cdecl("misstype_engine_new")
public func misstype_engine_new(
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
    engine.loadEnglishLexicon(resourceDirectory: URL(fileURLWithPath: resourceDir))
    
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

@_cdecl("misstype_engine_free")
public func misstype_engine_free(_ engine: OpaquePointer?) {
    if let engine = engine {
        releaseEngine(engine)
    }
}

@_cdecl("misstype_engine_set_settings")
public func misstype_engine_set_settings(
    _ engine: OpaquePointer?,
    _ settings: UnsafePointer<misstype_settings>?
) {
    guard let engine = engine, let settings = settings else { return }
    let handle = getEngine(engine)
    handle?.settings.value = SessionSettings(
        repairStrength: settings.pointee.fuzzy_repair == 0 ? .off
            : handle.map { $0.settings.value.fuzzyRepair ? $0.settings.value.repairStrength : .standard } ?? .standard,
        toneTolerance: settings.pointee.tone_tolerance != 0,
        candidateKeys: settings.pointee.candidate_keys.map { String(cString: $0) } ?? "asdfghjkl;",
        userLearning: settings.pointee.user_learning != 0,
        shiftToggle: settings.pointee.shift_toggle != 0,
        autoCommitSyllables: Int(max(0, settings.pointee.auto_commit_syllables)),
        autoShowCandidates: settings.pointee.auto_show_candidates != 0,
        returnConfirmsSelection: settings.pointee.return_confirms_selection != 0,
        mixedEnglish: settings.pointee.mixed_english != 0,
        pageSize: Int(settings.pointee.page_size),
        cursorCandidates: cursorCandidates(settings.pointee.cursor_candidates),
        channelLearning: handle?.settings.value.channelLearning ?? false
    )
}

/// `misstype_cursor_candidates` → `CursorCandidates`; unknown values keep the default.
private func cursorCandidates(_ value: Int32) -> CursorCandidates {
    switch UInt32(bitPattern: value) {
    case MISSTYPE_CURSOR_ENDING_AT.rawValue: return .endingAt
    case MISSTYPE_CURSOR_BEGINNING_AT.rawValue: return .beginningAt
    default: return .covering
    }
}

/// 0 off, 1 light, 2 standard, 3 strong (`RepairStrength`); out of range
/// is ignored. Kept across `misstype_engine_set_settings` unless that turns
/// `fuzzy_repair` off.
@_cdecl("misstype_engine_set_repair_strength")
public func misstype_engine_set_repair_strength(_ engine: OpaquePointer?, _ level: Int32) {
    guard let engine = engine, let handle = getEngine(engine),
          RepairStrength.allCases.indices.contains(Int(level)) else { return }
    handle.settings.value.repairStrength = RepairStrength.allCases[Int(level)]
}

@_cdecl("misstype_engine_set_channel_path")
public func misstype_engine_set_channel_path(_ engine: OpaquePointer?, _ path: UnsafePointer<CChar>?) {
    guard let engine = engine, let handle = getEngine(engine) else { return }
    let url: URL?
    if let path = path {
        let text = String(cString: path)
        url = text.isEmpty ? nil : URL(fileURLWithPath: text)
    } else {
        url = ChannelLearner.defaultURL
    }
    handle.engine.channelLearnerURL = url
    handle.engine.channelLearner = url.map { ChannelLearner.load(from: $0) } ?? ChannelLearner()
}

@_cdecl("misstype_engine_set_channel_learning")
public func misstype_engine_set_channel_learning(_ engine: OpaquePointer?, _ enabled: Int32) {
    guard let engine = engine, let handle = getEngine(engine) else { return }
    handle.settings.value.channelLearning = enabled != 0
}

@_cdecl("misstype_engine_clear_channel")
public func misstype_engine_clear_channel(_ engine: OpaquePointer?) {
    guard let engine = engine, let handle = getEngine(engine) else { return }
    handle.engine.clearChannel()
}

@_cdecl("misstype_engine_channel_pair_count")
public func misstype_engine_channel_pair_count(_ engine: OpaquePointer?) -> Int32 {
    guard let engine = engine, let handle = getEngine(engine) else { return 0 }
    return Int32(handle.engine.channelLearner.learnedPairs.count)
}

@_cdecl("misstype_engine_set_user_dictionary_path")
public func misstype_engine_set_user_dictionary_path(_ engine: OpaquePointer?, _ path: UnsafePointer<CChar>?) {
    guard let engine = engine, let handle = getEngine(engine) else { return }
    let url: URL?
    if let path = path {
        let text = String(cString: path)
        url = text.isEmpty ? nil : URL(fileURLWithPath: text)
    } else {
        url = UserDictionary.defaultURL
    }
    handle.engine.userDictionaryURL = url
    handle.engine.setUserDictionary(url.map { UserDictionary.load(from: $0) } ?? UserDictionary(), persist: false)
}

@_cdecl("misstype_engine_is_english")
public func misstype_engine_is_english(_ engine: OpaquePointer?) -> Int32 {
    guard let engine = engine else { return 0 }
    let handle = getEngine(engine)
    return handle?.engine.english == true ? 1 : 0
}

@_cdecl("misstype_session_new")
public func misstype_session_new(_ engine: OpaquePointer?) -> OpaquePointer? {
    guard let engine = engine else { return nil }
    let handle = getEngine(engine)
    guard let engineHandle = handle else { return nil }
    let session = InputSession(engine: engineHandle.engine)
    return retain(SessionHandle(session: session))
}

@_cdecl("misstype_session_free")
public func misstype_session_free(_ session: OpaquePointer?) {
    if let session = session {
        releaseSession(session)
    }
}

@_cdecl("misstype_session_handle")
public func misstype_session_handle(
    _ session: OpaquePointer?,
    _ event: UnsafePointer<misstype_key_event>?
) -> misstype_key_result {
    var result = misstype_key_result(consumed: 0, commit: nil, beep: 0, mode_changed: 0)
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

@_cdecl("misstype_session_commit")
public func misstype_session_commit(_ session: OpaquePointer?) -> UnsafeMutablePointer<CChar>? {
    guard let session = session else { return nil }
    let handle = getSession(session)
    guard let sessionHandle = handle else { return nil }
    let committed = sessionHandle.session.commit()
    return strdupOptional(committed)
}

@_cdecl("misstype_session_pick")
public func misstype_session_pick(_ session: OpaquePointer?, _ index: Int32) {
    guard let session = session else { return }
    let handle = getSession(session)
    handle?.session.pick(at: Int(index))
}

@_cdecl("misstype_session_reset_modifiers")
public func misstype_session_reset_modifiers(_ session: OpaquePointer?) {
    guard let session = session else { return }
    let handle = getSession(session)
    handle?.session.resetModifierState()
}

@_cdecl("misstype_session_raw_phonetic")
public func misstype_session_raw_phonetic(_ session: OpaquePointer?) -> UnsafeMutablePointer<CChar>? {
    guard let session = session else { return nil }
    let handle = getSession(session)
    return strdupOptional(handle?.session.rawPhonetic)
}

@_cdecl("misstype_session_view")
public func misstype_session_view(_ session: OpaquePointer?) -> UnsafeMutablePointer<misstype_view>? {
    guard let session = session else { return nil }
    let handle = getSession(session)
    guard let sessionHandle = handle else { return nil }
    let view = sessionHandle.session.view
    
    let viewPtr = UnsafeMutablePointer<misstype_view>.allocate(capacity: 1)
    viewPtr.initialize(to: misstype_view(
        preedit: strdupSwift(view.preedit),
        caret_bytes: Int32(caretBytes(view.preedit, caretUTF16: view.caret)),
        caret_utf16: Int32(view.caret),
        candidates: copyStringArray(view.candidates),
        candidate_count: Int32(view.candidates.count),
        selected: Int32(view.selected),
        selection_keys: copyStringArray(view.selectionKeys),
        selection_key_count: Int32(view.selectionKeys.count),
        keys_active: view.keysActive ? 1 : 0,
        shows_candidates: view.showsCandidates ? 1 : 0,
        mark_action: markAction(view.mark),
        mark_start_bytes: view.mark.map { Int32(caretBytes(view.preedit, caretUTF16: $0.range.lowerBound)) } ?? -1,
        mark_end_bytes: view.mark.map { Int32(caretBytes(view.preedit, caretUTF16: $0.range.upperBound)) } ?? -1,
        mark_start_utf16: view.mark.map { Int32($0.range.lowerBound) } ?? -1,
        mark_end_utf16: view.mark.map { Int32($0.range.upperBound) } ?? -1,
        mark_text: strdupSwift(view.mark?.text ?? ""),
        mark_reading: strdupSwift(view.mark?.reading ?? "")
    ))
    return viewPtr
}

@_cdecl("misstype_key_from_evdev")
public func misstype_key_from_evdev(_ evdev_code: Int32, _ label: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> misstype_key_kind {
    let key = EvdevKeyCode.key(Int(evdev_code))
    if let labelPtr = label {
        switch key {
        case .character(let l):
            labelPtr.pointee = staticLabels[l]
        default:
            labelPtr.pointee = nil
        }
    }
    return toMisstypeKey(key)
}

@_cdecl("misstype_key_from_character")
public func misstype_key_from_character(
    _ utf8: UnsafePointer<CChar>?,
    _ label: UnsafeMutablePointer<UnsafePointer<CChar>?>?,
    _ shifted: UnsafeMutablePointer<Int32>?
) -> misstype_key_kind {
    guard let utf8 = utf8 else { return MISSTYPE_KEY_OTHER }
    let string = String(cString: utf8)
    guard string.count == 1, let ch = string.first else { return MISSTYPE_KEY_OTHER }
    
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
        return toMisstypeKey(mapping.key)
    }
    return MISSTYPE_KEY_OTHER
}

@_cdecl("misstype_view_free")
public func misstype_view_free(_ view: UnsafeMutablePointer<misstype_view>?) {
    guard let view = view else { return }
    freeString(view.pointee.preedit)
    freeString(view.pointee.mark_text)
    freeString(view.pointee.mark_reading)
    freeStringArray(view.pointee.candidates, count: Int(view.pointee.candidate_count))
    freeStringArray(view.pointee.selection_keys, count: Int(view.pointee.selection_key_count))
    view.deallocate()
}

@_cdecl("misstype_string_free")
public func misstype_string_free(_ string: UnsafeMutablePointer<CChar>?) {
    freeString(string)
}