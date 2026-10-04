import Foundation
import InputMethodKit
import MisstypeCore

/// Bridges macOS `IMKTextInput` client to the platform-independent `TextInputContextClient` protocol.
final class IMKTextInputContextAdapter: TextInputContextClient {
    private weak var client: IMKTextInput?

    init(_ client: IMKTextInput) {
        self.client = client
    }

    func markedRange() -> NSRange {
        guard let client = client else { return NSRange(location: NSNotFound, length: 0) }
        return client.markedRange()
    }

    func selectedRange() -> NSRange {
        guard let client = client else { return NSRange(location: NSNotFound, length: 0) }
        return client.selectedRange()
    }

    func substring(in range: NSRange) -> String? {
        guard let client = client, range.location != NSNotFound, range.location >= 0,
              range.length > 0 else { return nil }
        // Clamp the window: surrounding context never needs more, and some
        // legacy client wrappers misbehave on wide ranges.
        let query = NSRange(location: range.location, length: min(range.length, 256))
        guard let direct = stringFromRange(query) else {
            return attributedSubstring(from: query)
        }
        return direct.isEmpty ? nil : direct
    }

    /// Direct string retrieval (fastest, no attribute parsing).
    /// Must provide a valid NSRange pointer for actualRange because macOS IMK's
    /// legacy client wrapper (_IPMDServerClientWrapperLegacy) unconditionally dereferences
    /// actualRange (*actualRange = ...) without checking for NULL, causing SIGSEGV if nil is passed.
    /// The wrapper itself has still segfaulted internally for clients that do
    /// not implement the call (Chromium/Electron, 2026-09-17 reports), so
    /// callers must only reach here when surrounding context is genuinely
    /// needed — and must check responds(to:) first.
    private func stringFromRange(_ range: NSRange) -> String? {
        guard let client = client,
              let object = client as? NSObject,
              object.responds(to: #selector(IMKTextInput.string(from:actualRange:))) else { return nil }
        var actualRange = NSRange(location: NSNotFound, length: 0)
        return client.string(from: range, actualRange: &actualRange)
    }

    /// Fallback to attributed substring if client does not implement stringFromRange.
    private func attributedSubstring(from range: NSRange) -> String? {
        guard let client = client,
              let object = client as? NSObject,
              object.responds(to: #selector(IMKTextInput.attributedSubstring(from:))) else { return nil }
        return client.attributedSubstring(from: range)?.string
    }

    func bundleIdentifier() -> String? {
        return client?.bundleIdentifier()
    }
}
