import Foundation
import InputMethodKit
import MistypeCore

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
        guard let client = client, range.location != NSNotFound, range.length > 0 else { return nil }
        // Try direct string retrieval first (fastest, no attribute parsing).
        if let direct = client.string(from: range, actualRange: nil), !direct.isEmpty {
            return direct
        }
        // Fallback to attributed substring if client does not implement stringFromRange.
        return client.attributedSubstring(from: range)?.string
    }

    func bundleIdentifier() -> String? {
        return client?.bundleIdentifier()
    }
}
