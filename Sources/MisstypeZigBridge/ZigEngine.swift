import CMisstype

/// Minimal Swift-facing handle for the Zig C ABI.
///
/// The IMK adapter still owns the richer Swift presentation model. This type
/// intentionally keeps the first cutover seam small and testable: it proves
/// that SwiftPM links the universal Zig library and that an engine/session can
/// be created and released with C ownership rules.
public final class ZigEngineProbe {
    public init() {}

    public var abiVersion: Int32 { misstype_abi_version() }

    /// Runs one synthetic composition and returns the preedit. The resource
    /// directory must contain lexicon.tsv and is supplied by the caller so
    /// tests never read a user's files.
    public func preedit(resourceDirectory: String) -> String? {
        let engine = resourceDirectory.withCString { path in
            misstype_engine_new(path, "".withCString { $0 })
        }
        guard let engine else { return nil }
        defer { misstype_engine_free(engine) }
        guard let session = misstype_session_new(engine) else { return nil }
        defer { misstype_session_free(session) }

        for byte in Array("su3".utf8) {
            var label = [CChar(bitPattern: byte), 0]
            let event = label.withUnsafeMutableBufferPointer { buffer -> misstype_key_event in
                misstype_key_event(kind: MISSTYPE_KEY_CHARACTER,
                                   label: UnsafePointer(buffer.baseAddress!), text: UnsafePointer(buffer.baseAddress!),
                                   modifiers: 0, is_release: 0, native_code: -1, timestamp: -1)
            }
            _ = misstype_session_handle(session, &event)
        }
        guard let view = misstype_session_view(session) else { return nil }
        defer { misstype_view_free(view) }
        guard let preedit = view.pointee.preedit else { return nil }
        return String(cString: preedit)
    }
}

/// Owning Swift handle used by the macOS adapter.
public final class ZigEngine {
    let handle: OpaquePointer

    public init?(resourceDirectory: URL, userLexiconPath: URL?) {
        let created: OpaquePointer? = resourceDirectory.path.withCString { resources in
            if let path = userLexiconPath?.path {
                return path.withCString { misstype_engine_new(resources, $0) }
            }
            return misstype_engine_new(resources, nil)
        }
        guard let created else { return nil }
        handle = created
    }

    deinit { misstype_engine_free(handle) }

    public var isEnglish: Bool { misstype_engine_is_english(handle) != 0 }

    public func makeSession() -> OpaquePointer? { misstype_session_new(handle) }
}
