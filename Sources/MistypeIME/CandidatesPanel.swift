import Cocoa
import MistypeCore

/// Own candidate window: single source of truth for the highlight.
/// IMKCandidates could display but never moved its highlight programmatically
/// (selectCandidateWithIdentifier: returns YES and does nothing; synthesized
/// events only beep), so selection state lives here and in the controller.
final class CandidatesPanel: NSPanel {
    private var rows: [NSButton] = []
    private let stack = NSStackView()
    private let preedit = NSTextField(labelWithString: "")
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
        // Preedit header: our own composition + cursor rendering (vChewing's
        // floating-buffer idea) — some clients never draw the marked-text
        // caret, so the cursor must be visible here regardless.
        preedit.font = .systemFont(ofSize: 13)
        preedit.lineBreakMode = .byTruncatingHead
        stack.addArrangedSubview(preedit)
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

    /// Max chars per row. Candidates share long prefixes and differ at the    /// tail (大對/大隊/大堆, 不大/便是/麼), so overlong rows truncate the
    /// FRONT and show the tail (… + suffix). Full text stays in marked text
    /// and commits.
    private let maxRowChars = 14

    private func displayText(_ text: String) -> String {
        guard text.count > maxRowChars else { return text }
        return "…" + String(text.suffix(maxRowChars))
    }

    /// Header content: composition with a colored cursor marker. The marker
    /// char comes last in the string, so a backwards search finds ours even
    /// if the composition somehow contained one already.
    private func preeditAttributed(_ text: String, caret: Int) -> NSAttributedString {
        let composed = MistypeCore.preeditWithCursor(text, caretUTF16: caret)
        let out = NSMutableAttributedString(
            string: composed,
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: NSColor.secondaryLabelColor])
        let ns = composed as NSString
        let found = ns.range(of: "|", options: .backwards)
        if found.location != NSNotFound {
            out.addAttribute(.foregroundColor, value: NSColor.labelColor, range: found)
        }
        return out
    }

    @objc override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    private func rowTitle(index: Int, text: String, highlighted: Bool) -> NSAttributedString {        let digit = NSMutableAttributedString(
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
    /// `selected` (Tab / Shift+Tab / Shift+digit walk the full list, no page
    /// keys; plain Left/Right move the syllable cursor and never page).
    /// `preedit` + `caret` render the composition with our own cursor on a
    /// header row (nil preedit hides it); `caret` is a UTF-16 offset.
    /// Frame stability (the anti-jitter contract): x sticky for the whole
    /// visible session, y bottom-anchored to the caret line. Width fits the
    /// widest content (rows or preedit header, capped) and eases via
    /// placeFrame instead of snapping — the panel breathes smoothly, never
    /// jumps or chases the caret horizontally mid-composition. Content
    /// itself always swaps instantly.
    private(set) var page = 0
    /// Max panel width: content fits below this; longer rows truncate
    /// (front) instead of stretching across the screen.
    private let panelWidth: CGFloat = 300
    /// Session x anchor: set when the panel opens, cleared on hide.
    private var sessionX: CGFloat?

    func update(candidates: [String], selected: Int, anchor: NSRect?,
                preedit: String? = nil, caret: Int = 0) {
        // Up to 64 rows pageable (single-char homophone lists); the visible
        // window stays 8, paging math below is count-generic.
        let total = Array(candidates.prefix(64))
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
        let pages = max((total.count + 7) / 8, 1)
        footer.stringValue = pages > 1 ? "\(page + 1) / \(pages)" : ""
        if let preedit {
            self.preedit.attributedStringValue = preeditAttributed(preedit, caret: caret)
            self.preedit.isHidden = false
        } else {
            self.preedit.isHidden = true
        }
        let headerHeight = self.preedit.isHidden ? 0 : rowHeight
        let height = CGFloat(shown.count) * rowHeight + 6 + 16 + headerHeight
        // Fitted width: rows or the preedit header, whichever is wider —
        // capped, eased by placeFrame, so the panel hugs content without
        // snapping. The header keeps long compositions (and a mid-sentence
        // cursor) visible instead of truncating early.
        var fittedWidth: CGFloat = 0
        for row in rows where !row.isHidden {
            fittedWidth = max(fittedWidth, row.fittingSize.width)
        }
        if !self.preedit.isHidden {
            fittedWidth = max(fittedWidth, self.preedit.fittingSize.width)
        }
        fittedWidth += 8 // stack leading/trailing insets
        if let anchor = anchor { lastAnchor = anchor }
        let target = anchor ?? lastAnchor
        if let anchor = target,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            let width = min(fittedWidth, panelWidth, visible.width)
            // Fixed direction: always above the caret (never covers the text
            // being typed); flip below only when clipped at the top. X is
            // sticky per visible session — typing advances the caret but the
            // panel stays put; only the height breathes, bottom-anchored.
            let originX: CGFloat
            if let sticky = sessionX {
                originX = min(max(sticky, visible.minX), visible.maxX - width)
            } else {
                originX = min(max(anchor.minX, visible.minX), visible.maxX - width)
                sessionX = originX
            }
            var origin = NSPoint(x: originX, y: anchor.maxY + 6)
            if origin.y + height > visible.maxY { origin.y = anchor.minY - height - 6 }
            placeFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)))
        } else {
            // No caret info at all (client without firstRect): park near the
            // mouse instead of the 0,0 corner; typing rarely moves the mouse.
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main {
                let visible = screen.visibleFrame
                let width = min(panelWidth, visible.width)
                let originX: CGFloat
                if let sticky = sessionX {
                    originX = min(max(sticky, visible.minX), visible.maxX - width)
                } else {
                    originX = min(max(mouse.x, visible.minX), visible.maxX - width)
                    sessionX = originX
                }
                var origin = NSPoint(x: originX, y: mouse.y + 12)
                if origin.y + height > visible.maxY { origin.y = mouse.y - height - 12 }
                placeFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)))
            } else {
                setContentSize(NSSize(width: panelWidth, height: height))
            }
        }
        orderFront(nil)
    }

    /// Frame placement: instant on first show (no fade-in weirdness), eased
    /// afterwards so resizes read as motion, not jumps. Content (rows,
    /// header, highlight) is always swapped synchronously before this runs.
    private func placeFrame(_ rect: NSRect) {
        guard isVisible else {
            setFrame(rect, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(rect, display: true)
        }
    }

    func hidePanel() {
        sessionX = nil
        orderOut(nil)
    }
}
