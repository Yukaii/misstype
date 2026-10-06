import Foundation
import MisstypeCore

// Required stubs for WASI libc++ / FoundationICU missing exception handling
@_cdecl("__cxa_allocate_exception")
public func __cxa_allocate_exception(_ size: Int) -> UnsafeMutableRawPointer? {
    fatalError("C++ exception not supported in WASI")
}

@_cdecl("__cxa_throw")
public func __cxa_throw(_ exception: UnsafeMutableRawPointer?, _ tinfo: UnsafeMutableRawPointer?, _ dest: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?) {
    fatalError("C++ exception not supported in WASI")
}

private final class WasmSessionHost: InputSessionHost {
    func surroundingContext() -> ClientContext {
        ClientContext(precedingText: "", bundleIdentifier: "wasm.browser")
    }
    func perform(_ work: @escaping () -> Void) {
        work()
    }
    func sessionDidChange(_ session: InputSession) {
        // Called when asynchronous state changes
    }
}

private var globalEngine: InputEngine?
private var globalSession: InputSession?
private var wasmHost = WasmSessionHost()
private var lastResult: KeyResult = KeyResult(consumed: false)
private var lastCommittedText: String?
private var currentSettings = SessionSettings()

// JSON output buffer kept alive across calls until next state request
private var stateJsonBuffer: [UInt8] = []

@_cdecl("misstype_wasm_alloc")
public func misstype_wasm_alloc(_ size: Int) -> UnsafeMutableRawPointer {
    return UnsafeMutableRawPointer.allocate(byteCount: max(1, size), alignment: 1)
}

@_cdecl("misstype_wasm_free")
public func misstype_wasm_free(_ ptr: UnsafeMutableRawPointer) {
    ptr.deallocate()
}

@_cdecl("misstype_wasm_init")
public func misstype_wasm_init(
    _ lexiconPtr: UnsafePointer<UInt8>,
    _ lexiconLen: Int,
    _ tonelessPtr: UnsafePointer<UInt8>,
    _ tonelessLen: Int
) -> Int32 {
    let lexiconStr = String(decoding: UnsafeBufferPointer(start: lexiconPtr, count: lexiconLen), as: UTF8.self)
    let tonelessStr = tonelessLen > 0
        ? String(decoding: UnsafeBufferPointer(start: tonelessPtr, count: tonelessLen), as: UTF8.self)
        : ""

    let decoder = LexiconDecoder(tsv: lexiconStr, toneless: tonelessStr)
    decoder.wordPenalty = LexiconLoader.defaultWordPenalty

    currentSettings.returnConfirmsSelection = true
    currentSettings.autoShowCandidates = false
    currentSettings.shiftToggle = true

    let engine = InputEngine(
        decoder: decoder,
        settings: { currentSettings },
        log: { msg in
            print("[MisstypeWasm] \(msg)")
        }
    )
    engine.shiftTap.tapTimeLimit = 0.35

    let session = InputSession(engine: engine)
    session.host = wasmHost

    globalEngine = engine
    globalSession = session
    lastResult = KeyResult(consumed: false)
    lastCommittedText = nil

    return 1
}

private func parseKeyCode(_ code: String, keyText: String) -> KeyEvent.Key {
    switch code {
    case "Space": return .space
    case "Enter", "NumpadEnter": return .enter
    case "Tab": return .tab
    case "Backspace": return .backspace
    case "Delete": return .forwardDelete
    case "Escape": return .escape
    case "ArrowLeft": return .left
    case "ArrowRight": return .right
    case "ArrowUp": return .up
    case "ArrowDown": return .down
    case "PageUp": return .pageUp
    case "PageDown": return .pageDown
    case "ShiftLeft": return .shift(.left)
    case "ShiftRight": return .shift(.right)
    case "ControlLeft", "ControlRight", "AltLeft", "AltRight", "MetaLeft", "MetaRight":
        return .modifier
    default:
        break
    }

    if code.hasPrefix("Key") && code.count == 4 {
        let letter = String(code.suffix(1)).lowercased()
        return .character(letter)
    }
    if code.hasPrefix("Digit") && code.count == 6 {
        let digit = String(code.suffix(1))
        return .character(digit)
    }

    switch code {
    case "Minus": return .character("-")
    case "Equal": return .character("=")
    case "BracketLeft": return .character("[")
    case "BracketRight": return .character("]")
    case "Backslash": return .character("\\")
    case "Semicolon": return .character(";")
    case "Quote": return .character("'")
    case "Backquote": return .character("`")
    case "Comma": return .character(",")
    case "Period": return .character(".")
    case "Slash": return .character("/")
    default:
        if keyText.count == 1 {
            return .character(keyText.lowercased())
        }
        return .other
    }
}

@_cdecl("misstype_wasm_handle_key")
public func misstype_wasm_handle_key(
    _ codePtr: UnsafePointer<UInt8>,
    _ codeLen: Int,
    _ textPtr: UnsafePointer<UInt8>,
    _ textLen: Int,
    _ modifiersRaw: Int32,
    _ phaseRaw: Int32,
    _ timestamp: Double
) -> Int32 {
    guard let session = globalSession else { return 0 }

    let code = String(decoding: UnsafeBufferPointer(start: codePtr, count: codeLen), as: UTF8.self)
    let text = textLen > 0 ? String(decoding: UnsafeBufferPointer(start: textPtr, count: textLen), as: UTF8.self) : nil

    let key = parseKeyCode(code, keyText: text ?? "")
    let phase: KeyEvent.Phase = (phaseRaw == 1) ? .release : .press

    var modifiers: KeyEvent.Modifiers = []
    if (modifiersRaw & 1) != 0 { modifiers.insert(.shift) }
    if (modifiersRaw & 2) != 0 { modifiers.insert(.control) }
    if (modifiersRaw & 4) != 0 { modifiers.insert(.option) }
    if (modifiersRaw & 8) != 0 { modifiers.insert(.command) }
    if (modifiersRaw & 16) != 0 { modifiers.insert(.capsLock) }

    let event = KeyEvent(
        key,
        phase: phase,
        modifiers: modifiers,
        text: text,
        timestamp: timestamp > 0 ? timestamp : nil
    )

    let result = session.handle(event)
    lastResult = result
    if let commit = result.commit {
        lastCommittedText = (lastCommittedText ?? "") + commit
    }

    return result.consumed ? 1 : 0
}

@_cdecl("misstype_wasm_pick_candidate")
public func misstype_wasm_pick_candidate(_ index: Int32) {
    guard let session = globalSession else { return }
    session.pick(at: Int(index))
}

@_cdecl("misstype_wasm_commit")
public func misstype_wasm_commit() -> Int32 {
    guard let session = globalSession else { return 0 }
    if let text = session.commit() {
        lastCommittedText = (lastCommittedText ?? "") + text
        return 1
    }
    return 0
}

@_cdecl("misstype_wasm_reset")
public func misstype_wasm_reset() {
    guard let engine = globalEngine else { return }
    let session = InputSession(engine: engine)
    session.host = wasmHost
    globalSession = session
    lastCommittedText = nil
    lastResult = KeyResult(consumed: false)
}

@_cdecl("misstype_wasm_clear_committed")
public func misstype_wasm_clear_committed() {
    lastCommittedText = nil
}

@_cdecl("misstype_wasm_toggle_english")
public func misstype_wasm_toggle_english() -> Int32 {
    guard let session = globalSession, let engine = globalEngine else { return 0 }
    if let commit = session.commit() {
        lastCommittedText = (lastCommittedText ?? "") + commit
    }
    engine.english.toggle()
    return engine.english ? 1 : 0
}

@_cdecl("misstype_wasm_set_english")
public func misstype_wasm_set_english(_ enabled: Int32) -> Int32 {
    guard let session = globalSession, let engine = globalEngine else { return 0 }
    let target = (enabled != 0)
    if engine.english != target {
        if let commit = session.commit() {
            lastCommittedText = (lastCommittedText ?? "") + commit
        }
        engine.english = target
    }
    return engine.english ? 1 : 0
}

@_cdecl("misstype_wasm_set_setting")
public func misstype_wasm_set_setting(
    _ keyPtr: UnsafePointer<UInt8>,
    _ keyLen: Int,
    _ value: Int32
) {
    let key = String(decoding: UnsafeBufferPointer(start: keyPtr, count: keyLen), as: UTF8.self)
    switch key {
    case "autoShowCandidates":
        currentSettings.autoShowCandidates = (value != 0)
    case "returnConfirmsSelection":
        currentSettings.returnConfirmsSelection = (value != 0)
    case "shiftToggle":
        currentSettings.shiftToggle = (value != 0)
    case "pageSize":
        currentSettings.pageSize = Int(value)
    default:
        break
    }
}

private func escapeJsonString(_ str: String) -> String {
    var out = "\""
    for scalar in str.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.append(Character(scalar))
            }
        }
    }
    out += "\""
    return out
}

@_cdecl("misstype_wasm_get_state_json")
public func misstype_wasm_get_state_json() -> UnsafePointer<UInt8>? {
    guard let session = globalSession, let engine = globalEngine else {
        let empty = "{}".utf8CString
        stateJsonBuffer = empty.map { UInt8(bitPattern: $0) }
        return stateJsonBuffer.withUnsafeBufferPointer { $0.baseAddress }
    }

    let view = session.view
    let pageSize = max(1, view.pageSize)
    let page = view.selected / pageSize
    let pageCount = max(1, (view.candidates.count + pageSize - 1) / pageSize)
    let pageStart = page * pageSize
    let pageEnd = min(pageStart + pageSize, view.candidates.count)
    let pageCandidates: [String]
    if pageStart < view.candidates.count {
        pageCandidates = Array(view.candidates[pageStart..<pageEnd])
    } else {
        pageCandidates = []
    }
    let pageSelected = view.selected % pageSize

    var json = "{"
    json += "\"preedit\":\(escapeJsonString(view.preedit)),"
    json += "\"caret\":\(view.caret),"
    json += "\"selected\":\(view.selected),"
    json += "\"showsCandidates\":\(view.showsCandidates ? "true" : "false"),"
    json += "\"keysActive\":\(view.keysActive ? "true" : "false"),"
    json += "\"pageSize\":\(pageSize),"
    json += "\"page\":\(page),"
    json += "\"pageCount\":\(pageCount),"
    json += "\"pageSelected\":\(pageSelected),"

    // Candidates array
    json += "\"candidates\":["
    json += view.candidates.map { escapeJsonString($0) }.joined(separator: ",")
    json += "],"

    // Page candidates array
    json += "\"pageCandidates\":["
    json += pageCandidates.map { escapeJsonString($0) }.joined(separator: ",")
    json += "],"

    // Selection keys
    json += "\"selectionKeys\":["
    json += view.selectionKeys.map { escapeJsonString($0) }.joined(separator: ",")
    json += "],"

    // Segments: array of [start, end]
    json += "\"segments\":["
    json += view.segments.map { "[\($0.lowerBound),\($0.upperBound)]" }.joined(separator: ",")
    json += "],"

    // Focus: [start, end] or null
    if let focus = view.focus {
        json += "\"focus\":[\(focus.lowerBound),\(focus.upperBound)],"
    } else {
        json += "\"focus\":null,"
    }

    // Mark
    if let mark = view.mark {
        let actionStr: String
        switch mark.action {
        case .add: actionStr = "add"
        case .remove: actionStr = "remove"
        case .tooShort: actionStr = "tooShort"
        case .tooLong: actionStr = "tooLong"
        case .unavailable: actionStr = "unavailable"
        }
        json += "\"mark\":{\"range\":[\(mark.range.lowerBound),\(mark.range.upperBound)],\"reading\":\(escapeJsonString(mark.reading)),\"action\":\(escapeJsonString(actionStr))},"
    } else {
        json += "\"mark\":null,"
    }

    // Committed text
    if let commit = lastCommittedText {
        json += "\"lastCommit\":\(escapeJsonString(commit)),"
    } else {
        json += "\"lastCommit\":null,"
    }

    // KeyResult fields
    json += "\"consumed\":\(lastResult.consumed ? "true" : "false"),"
    json += "\"beep\":\(lastResult.beep ? "true" : "false"),"
    json += "\"modeChanged\":\(lastResult.modeChanged ? "true" : "false"),"
    json += "\"latinToggled\":\(lastResult.latinToggled ? "true" : "false"),"

    // Engine mode
    json += "\"english\":\(engine.english ? "true" : "false"),"
    json += "\"latinActive\":\(session.latinActive ? "true" : "false")"

    json += "}"

    let cStr = json.utf8CString
    stateJsonBuffer = cStr.map { UInt8(bitPattern: $0) }
    return stateJsonBuffer.withUnsafeBufferPointer { $0.baseAddress }
}

print("[MisstypeWasm] Module loaded")
