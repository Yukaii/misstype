import AppKit
import MisstypeCore

/// Clients whose `IMKTextInput` marked text cannot be trusted (vChewing's
/// "mitigation level 2", checked against its LibVanguard source 2026-10-06):
/// Electron/WebView apps draw nothing, or something broken, for marked text.
/// There the composition is drawn in `CompositionPopup` and the client only
/// gets a one-space placeholder, which keeps IMK from deciding the
/// composition ended and leaking later keys to the app.
enum ClientMitigation {
    /// Apps known to mishandle marked text that are not Electron.
    static let builtinIncapable: Set<String> = [
        "com.valvesoftware.steam", "jp.naver.line.mac", "org.alacritty", "com.github.wez.wezterm",
    ]

    /// The menu toggle: flip this app between the popup and native marked
    /// text, whatever the rules currently say.
    static func togglePopup(bundleID: String) {
        var popup = MisstypePrefs.popupCompositionClients
        var native = MisstypePrefs.nativeCompositionClients
        if needsPopup(bundleID: bundleID) {
            popup.remove(bundleID)
            native.insert(bundleID)
        } else {
            native.remove(bundleID)
            popup.insert(bundleID)
        }
        MisstypePrefs.popupCompositionClients = popup
        MisstypePrefs.nativeCompositionClients = native
    }

    private static var cache: [String: Bool] = [:]

    static func needsPopup(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty, !MisstypePrefs.popupCompositionDisabled else { return false }
        if MisstypePrefs.nativeCompositionClients.contains(bundleID) { return false }
        if builtinIncapable.contains(bundleID) || MisstypePrefs.popupCompositionClients.contains(bundleID) {
            return true
        }
        guard MisstypePrefs.popupCompositionForElectron else { return false }
        if let known = cache[bundleID] { return known }
        let result = isElectronBased(bundleID: bundleID)
        // A client that is not running yet cannot be inspected: do not cache.
        if result != nil { cache[bundleID] = result }
        return result ?? false
    }

    /// nil = the app is not running (nothing to inspect).
    private static func isElectronBased(bundleID: String) -> Bool? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let url = apps.compactMap(\.bundleURL).first, let bundle = Bundle(url: url) else { return nil }
        return bundle.looksElectronBased
    }
}

private extension Bundle {
    /// Info.plist mentions Electron, or the app ships an Electron/WebView
    /// framework (vChewing's rule).
    var looksElectronBased: Bool {
        if let info = infoDictionary {
            if info.keys.contains(where: { $0.lowercased().contains("electron") }) { return true }
            if info.values.contains(where: { ($0 as? CustomStringConvertible)?.description.lowercased().contains("electron") ?? false }) {
                return true
            }
        }
        guard let frameworks = privateFrameworksURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else { return false }
        return names.contains { name in
            let lower = name.lowercased()
            return lower.contains("electron") || lower.contains("mswebview") || lower.contains("slimcorewebview")
        }
    }
}

/// Floating composition buffer: the preedit with its caret (and phrase
/// mark) for clients that cannot show marked text. Borderless, nonactivating
/// like the candidate panel; sits just below the caret (the candidate panel
/// opens above it).
final class CompositionPopup: NSPanel {
    static let shared = CompositionPopup()

    private let label = NSTextField(labelWithString: "")

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 80, height: 28),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
        let body = NSView()
        body.wantsLayer = true
        body.layer?.cornerRadius = 6
        contentView = body
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        body.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var sessionX: CGFloat?

    func show(preedit: String, caret: Int, mark: SessionView.Mark?, anchor: NSRect?) {
        let fontSize = max(PanelStyle.defaultFontSize, 16)
        let font = NSFont.systemFont(ofSize: fontSize)
        // Single line that never wraps: an attributed string carries its own
        // paragraph style, which beat the label's lineBreakMode and wrapped
        // the tail (last character, end caret) onto a hidden second line.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        let text = NSMutableAttributedString(string: preedit, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .paragraphStyle: paragraph,
        ])
        if let mark {
            let range = NSRange(location: mark.range.lowerBound, length: mark.range.count)
            if NSMaxRange(range) <= text.length {
                text.addAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, range: range)
            }
        }
        // The caret: a thin bar between units, as the client would draw it.
        let at = min(max(caret, 0), text.length)
        // ASCII bar, not a block-element glyph: "▏" falls back to a CJK-wide
        // font and reads as a character slot, hiding the focused character.
        text.insert(NSAttributedString(string: "|", attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .light),
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: 0,
            .paragraphStyle: paragraph,
        ]), at: at)
        label.attributedStringValue = text
        let textSize = text.size()
        // NSTextField's cell insets the text a few points per side: size the
        // label from its own cell so the last glyph always fits.
        let labelWidth = min(ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 1_000)).width ?? textSize.width), 400)
        let width = labelWidth + 20
        let height = ceil(textSize.height) + 10
        label.frame = NSRect(x: 10, y: 5, width: labelWidth, height: ceil(textSize.height) + 2)
        (contentView as? NSView)?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let frame = Self.frame(width: width, height: height, anchor: anchor, sessionX: &sessionX)
        setFrame(frame, display: true)
        orderFront(nil)
    }

    private static func frame(width: CGFloat, height: CGFloat, anchor: NSRect?, sessionX: inout CGFloat?) -> NSRect {
        let point = anchor?.origin ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = sessionX ?? min(max(anchor?.minX ?? point.x, visible.minX), visible.maxX - width)
        sessionX = x
        var y = anchor.map { $0.minY - height - 6 } ?? point.y - height - 12
        if y < visible.minY { y = (anchor?.maxY ?? point.y) + 6 }
        return NSRect(x: min(x, visible.maxX - width), y: y, width: width, height: height)
    }

    func hidePopup() {
        sessionX = nil
        orderOut(nil)
    }
}
