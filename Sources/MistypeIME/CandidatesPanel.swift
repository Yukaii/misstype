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
    }

    @objc private func rowClicked(_ sender: NSButton) {
        onPick(sender.tag)
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
    func update(candidates: [String], selected: Int, anchor: NSRect?) {
        let shown = Array(candidates.prefix(8))
        for (index, text) in shown.enumerated() {
            let row = rows[index]
            row.title = ""
            row.attributedTitle = rowTitle(index: index, text: displayText(text),
                                           highlighted: index == selected)
            row.isHidden = false
            row.wantsLayer = true
            row.layer?.cornerRadius = 6
            // Neutral gray highlight on purpose: selectedContentBackgroundColor
            // follows the system accent (pink on this machine) and looks drunk.
            row.layer?.backgroundColor = index == selected
                ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
                : CGColor.clear
        }
        for index in shown.count..<rows.count { rows[index].isHidden = true }
        // Self-sized: ask the buttons, not a guessed padding constant.
        var width: CGFloat = 0
        for row in rows where !row.isHidden {
            width = max(width, row.fittingSize.width)
        }
        width = min(max(width + 8, 44), 360)
        let height = CGFloat(shown.count) * rowHeight + 6
        if let anchor = anchor { lastAnchor = anchor }
        let target = anchor ?? lastAnchor
        if let anchor = target,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            var origin = NSPoint(x: anchor.minX, y: anchor.minY - height - 6)
            origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
            if origin.y < visible.minY { origin.y = anchor.maxY + 6 }
            setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        } else {
            // No caret info at all (client without firstRect): park near the
            // mouse instead of the 0,0 corner; typing rarely moves the mouse.
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main {
                let visible = screen.visibleFrame
                var origin = NSPoint(x: mouse.x, y: mouse.y - height - 12)
                origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
                origin.y = min(max(origin.y, visible.minY), visible.maxY - height)
                setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
            } else {
                setContentSize(NSSize(width: width, height: height))
            }
        }
        orderFront(nil)
    }

    func hidePanel() {
        orderOut(nil)
    }
}
