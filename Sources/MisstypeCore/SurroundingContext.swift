import Foundation

/// Protocol abstracting a text input client that provides context around the cursor.
/// Conformed to by live macOS IMKTextInput adapters in MisstypeIME, and by test doubles in tests.
public protocol TextInputContextClient: AnyObject {
    func markedRange() -> NSRange
    func selectedRange() -> NSRange
    func substring(in range: NSRange) -> String?
    func bundleIdentifier() -> String?
}

/// Surrounding client context snapshot captured from an active text field.
public struct ClientContext: Equatable {
    /// Preceding committed text before the active composition/caret.
    public var precedingText: String
    /// Bundle identifier of the frontmost application hosting the input session.
    public var bundleIdentifier: String?

    public init(precedingText: String = "", bundleIdentifier: String? = nil) {
        self.precedingText = precedingText
        self.bundleIdentifier = bundleIdentifier
    }

    public var isEmpty: Bool {
        precedingText.isEmpty
    }
}

/// Safe extractor for surrounding text context from a text input client.
/// Strictly bounds the extraction window and sanitizes control characters.
public enum SurroundingContext {
    public static let defaultMaxCharacters = 60

    /// Extracts preceding text before the active marked range or cursor position.
    ///
    /// - Parameters:
    ///   - client: The text input client protocol.
    ///   - maxCharacters: Maximum UTF-16 character count to look back (default 60).
    /// - Returns: Preceding context string, or empty string if none available.
    public static func extractPrecedingText(from client: TextInputContextClient?,
                                           maxCharacters: Int = defaultMaxCharacters) -> String {
        guard let client = client, maxCharacters > 0 else { return "" }

        let marked = client.markedRange()
        let selected = client.selectedRange()

        // If composing/marked text exists and has a valid location, use its start;
        // otherwise fall back to cursor (selectedRange.location).
        let anchorLocation: Int
        if marked.location != NSNotFound {
            anchorLocation = marked.location
        } else if selected.location != NSNotFound {
            anchorLocation = selected.location
        } else {
            return ""
        }

        guard anchorLocation > 0 else { return "" }

        let fetchLength = min(anchorLocation, maxCharacters)
        let fetchStart = anchorLocation - fetchLength
        let queryRange = NSRange(location: fetchStart, length: fetchLength)

        guard let text = client.substring(in: queryRange) else { return "" }
        return sanitize(text)
    }

    /// Extracts both preceding text and app bundle identifier.
    public static func extract(from client: TextInputContextClient?,
                               maxCharacters: Int = defaultMaxCharacters) -> ClientContext {
        let text = extractPrecedingText(from: client, maxCharacters: maxCharacters)
        let bundle = client?.bundleIdentifier()
        return ClientContext(precedingText: text, bundleIdentifier: bundle)
    }

    /// Sanitizes extracted text: strips null bytes and unprintable control characters
    /// (< 0x20 except \t, \n), preserving normal typography and whitespace.
    public static func sanitize(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return String(text.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            return scalar.value >= 0x20 && scalar.value != 0x7F
        })
    }
}
