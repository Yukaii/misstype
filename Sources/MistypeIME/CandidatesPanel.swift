import Cocoa

/// Own candidate window: single source of truth for the highlight.
/// IMKCandidates could display but never moved its highlight programmatically
/// (selectCandidateWithIdentifier: returns YES and does nothing; synthesized
/// events only beep), so selection state lives here and in the controller.
final class CandidatesPanel: NSPanel {
    private var rows: [NSButton] = []
    private let stack = NSStackView()
    private var onPick: (Int) -> Void = { _ in }
    private let rowHeight: CGFloat = 28
    private var lastAnchor: NSRect?
    private let footer = NSTextField(labelWithString: "")

    init(onPick: @escaping (Int) -> Void) {
        self.onPick = onPick
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none

        let body = NSView(frame: .zero)
        body.wantsLayer = true
        body.layer?.cornerRadius = 10
        body.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView = body

        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: body.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -3),
        ])
        for index in 0..<8 {
            let row = NSButton(title: "", target: self, action: #selector(rowClicked(_:)))
            row.tag = index
            row.bezelStyle = .inline
            row.bezelColor = .clear
            row.isBordered = false
            row.font = .systemFont(ofSize: 15)
            row.alignment = .left
            row.contentTintColor = .labelColor
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            rows.append(row)
            stack.addArrangedSubview(row)
        }
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .right
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.heightAnchor.constraint(equalToConstant: 16).isActive = true
        stack.addArrangedSubview(footer)
    }

    @objc private func rowClicked(_ sender: NSButton) {
        onPick(page * 8 + sender.tag)
    }

    /// Max chars per row. Candidates share long prefixes and differ at the
    /// tail (大對/大隊/大堆, 不大/便是/麼), so overlong rows truncate the
    /// FRONT and show the tail (… + suffix). Full text stays in marked text
    /// and commits.
    private let maxRowChars = 14

    private func displayText(_ text: String) -> String {
        guard text.count > maxRowChars else { return text }
        return "…" + String(text.suffix(maxRowChars))
    }

    @objc override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    private func rowTitle(index: Int, text: String, highlighted: Bool) -> NSAttributedString {
        let digit = NSMutableAttributedString(
            string: "\(index + 1)  ",
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: NSColor.secondaryLabelColor])
        let body = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 15),
                         .foregroundColor: NSColor.labelColor])
        digit.append(body)
        return digit
    }

    /// Rebuild rows, move highlight, follow the caret. No-op animations.
    /// Anchor chain: fresh caret rect > last good rect > mouse position.
    /// Paging is a window over the list: 8 rows show the page holding
    /// `selected` (Tab/arrows/digits walk the full list, no page keys).
    private(set) var page = 0

    func update(candidates: [String], selected: Int, anchor: NSRect?) {
        let total = Array(candidates.prefix(16))
        page = min(max(selected, 0) / 8, max(total.count - 1, 0) / 8)
        let shown = Array(total.dropFirst(page * 8).prefix(8))
        for (index, text) in shown.enumerated() {
            let row = rows[index]
            row.title = ""
            row.attributedTitle = rowTitle(index: index, text: displayText(text),
                                           highlighted: index == selected - page * 8)
            row.isHidden = false
            row.wantsLayer = true
            row.layer?.cornerRadius = 6
            // Neutral gray highlight on purpose: selectedContentBackgroundColor
            // follows the system accent (pink on this machine) and looks drunk.
            row.layer?.backgroundColor = index == selected - page * 8
                ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
                : CGColor.clear
        }
        for index in shown.count..<rows.count { rows[index].isHidden = true }
        // Dynamic width: fit the widest visible row (buttons measure
        // themselves, insets included), clamped to the screen. No floor —
        // single-character lists stay narrow.
        var contentWidth: CGFloat = 0
        for row in rows where !row.isHidden {
            contentWidth = max(contentWidth, row.fittingSize.width)
        }
        contentWidth += 8 // stack leading/trailing insets
        let pages = max((total.count + 7) / 8, 1)
        footer.stringValue = pages > 1 ? "\(page + 1) / \(pages)" : ""
        let height = CGFloat(shown.count) * rowHeight + 6 + 16
        if let anchor = anchor { lastAnchor = anchor }
        let target = anchor ?? lastAnchor
        if let anchor = target,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            let width = min(contentWidth, visible.width)
            // Fixed direction: always above the caret (never covers the text
            // being typed); flip below only when clipped at the top.
            var origin = NSPoint(x: anchor.minX, y: anchor.maxY + 6)
            origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
            if origin.y + height > visible.maxY { origin.y = anchor.minY - height - 6 }
            setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        } else {
            // No caret info at all (client without firstRect): park near the
            // mouse instead of the 0,0 corner; typing rarely moves the mouse.
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main {
                let visible = screen.visibleFrame
                let width = min(contentWidth, visible.width)
                var origin = NSPoint(x: mouse.x, y: mouse.y + 12)
                origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
                if origin.y + height > visible.maxY { origin.y = mouse.y - height - 12 }
                setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
            } else {
                setContentSize(NSSize(width: contentWidth, height: height))
            }
        }
        orderFront(nil)
    }

    func hidePanel() {
        orderOut(nil)
    }
}
