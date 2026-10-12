import Cocoa
import MisstypeMacKit

// MARK: - Sketches

/// A static drawing of the candidate panel in a palette (not the real
/// panel). `palette` nil = the system colors, as the panel draws them.
final class PanelSketchView: NSView {
    var palette: PanelTheme.Palette? { didSet { needsDisplay = true } }
    var style = PanelStyle() {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    /// nil = follow the window; true/false force dark/light.
    var forceDark: Bool? {
        didSet {
            appearance = forceDark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
            needsDisplay = true
        }
    }
    /// Intrinsic width; constraints may stretch it.
    var width: CGFloat = 180 { didSet { invalidateIntrinsicContentSize() } }
    private let rows = ["你好", "妳好", "擬好"]
    private let keys = ["a", "s", "d"]

    override var isFlipped: Bool { true }

    private var rowHeight: CGFloat { (style.fontSize * 28 / 15).rounded() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width, height: rowHeight * CGFloat(rows.count) + 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let panel = bounds.insetBy(dx: 0.5, dy: 0.5)
            let background = NSBezierPath(roundedRect: panel, xRadius: CGFloat(style.cornerRadius),
                                          yRadius: CGFloat(style.cornerRadius))
            (palette?.background ?? .windowBackgroundColor).setFill()
            background.fill()
            NSColor.separatorColor.setStroke()
            background.lineWidth = 0.5
            background.stroke()
            for (index, text) in rows.enumerated() {
                let rect = NSRect(x: 4, y: 4 + CGFloat(index) * rowHeight, width: bounds.width - 8, height: rowHeight)
                if index == 0 {
                    (palette?.highlight ?? .unemphasizedSelectedContentBackgroundColor).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: style.rowCornerRadius, yRadius: style.rowCornerRadius).fill()
                }
                let key = NSAttributedString(string: keys[index], attributes: [
                    .font: style.keyFont, .foregroundColor: palette?.key ?? NSColor.secondaryLabelColor])
                let word = NSAttributedString(string: text, attributes: [
                    .font: style.wordFont, .foregroundColor: palette?.text ?? NSColor.labelColor])
                let keySize = key.size(), wordSize = word.size()
                key.draw(at: NSPoint(x: rect.minX + 8, y: rect.midY - keySize.height / 2))
                word.draw(at: NSPoint(x: rect.minX + 8 + max(keySize.width, 8) + 8, y: rect.midY - wordSize.height / 2))
            }
        }
    }
}

/// Four overlapping dots (background, highlighted row, key, text): a
/// one-line summary of a scheme.
final class ThemeDotsView: NSView {
    var palette: PanelTheme.Palette? { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 14 + 3 * 10, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let colors: [NSColor] = palette.map { [$0.background, $0.highlight, $0.key, $0.text] }
                ?? [.windowBackgroundColor, .quaternaryLabelColor, .secondaryLabelColor, .labelColor]
            for (index, color) in colors.enumerated() {
                let rect = NSRect(x: CGFloat(index) * 10, y: 0, width: 14, height: 14).insetBy(dx: 0.5, dy: 0.5)
                let dot = NSBezierPath(ovalIn: rect)
                color.setFill()
                dot.fill()
                NSColor.separatorColor.setStroke()
                dot.stroke()
            }
        }
    }
}

/// One gallery card: the sketch in a rounded tile, ringed when selected.
/// A plain view with explicit constraints; NSBox did not size from an
/// auto-layout content view and collapsed to nothing.
final class ThemeCardView: NSView {
    let sketch = PanelSketchView()
    var selected = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 2
        sketch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sketch)
        NSLayoutConstraint.activate([
            sketch.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            sketch.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            sketch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            sketch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            layer?.borderColor = (selected ? NSColor.controlAccentColor : .clear).cgColor
        }
    }
}

// MARK: - Studio

/// Theme gallery and custom-color editor, shown as a sheet from Appearance.
final class ThemeStudioController: NSViewController {
    private static let themeKey = "MisstypePanelTheme"

    /// nil = follow the panel appearance setting; the segmented control
    /// overrides it for browsing and for choosing which half to edit.
    private var showDark: Bool?
    private let segments = NSSegmentedControl(labels: [L("Light"), L("Dark")], trackingMode: .selectOne,
                                              target: nil, action: nil)
    private var cards: [(theme: PanelTheme, tile: ThemeCardView)] = []
    private let editor = NSStackView()
    private var wells: [NSColorWell] = []
    private var fields: [NSTextField] = []
    private var warnings: [NSImageView] = []
    private let linked = NSSwitch()
    private let scopeNote = UI.caption("", width: 340)
    private let message = UI.caption("", width: 340)
    private let bigSketch = PanelSketchView()
    private var observer: NSObjectProtocol?

    private var themeValue: PanelTheme {
        PanelTheme(rawValue: UserDefaults.standard.string(forKey: Self.themeKey) ?? "") ?? .system
    }

    private var customText: String {
        get { UserDefaults.standard.string(forKey: CustomTheme.userDefaultsKey) ?? CustomTheme.defaultText }
        set { UserDefaults.standard.set(newValue, forKey: CustomTheme.userDefaultsKey) }
    }

    private var dark: Bool {
        if let showDark { return showDark }
        switch PanelStyle.Appearance(rawValue: UserDefaults.standard.string(forKey: "MisstypePanelAppearance") ?? "") ?? .system {
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        case .light: return false
        case .dark: return true
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 560))
        view = root

        let title = UI.label(L("Color scheme"), size: 15, weight: .semibold)
        segments.onAction { [weak self] in
            guard let self else { return }
            self.showDark = self.segments.selectedSegment == 1
            self.render()
        }
        let done = UI.button(L("Done")) { [weak self] in self?.dismiss(nil) }
        done.keyEquivalent = "\r"
        let header = UI.hstack([title, NSView(), segments, done], spacing: 12)
        header.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Gallery: two rows of three cards.
        let themes = PanelTheme.allCases
        let rows = stride(from: 0, to: themes.count, by: 3).map { start -> NSStackView in
            let row = NSStackView(views: themes[start..<min(start + 3, themes.count)].map(makeCard))
            row.distribution = .fillEqually
            row.spacing = 14
            return row
        }
        let gallery = UI.vstack(rows, spacing: 14)
        for row in rows { row.widthAnchor.constraint(equalTo: gallery.widthAnchor).isActive = true }

        buildEditor()
        let content = UI.vstack([gallery, editor], spacing: 20)
        gallery.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        editor.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
        ])

        root.addSubview(header)
        root.addSubview(separator)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 640),
            root.heightAnchor.constraint(equalToConstant: 560),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.render()
        }
        render()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    // MARK: Cards

    private func makeCard(_ theme: PanelTheme) -> NSView {
        let tile = ThemeCardView()
        let name = UI.label(theme.title, size: NSFont.smallSystemFontSize)
        name.alignment = .center
        let card = UI.vstack([tile, name], spacing: 6)
        card.alignment = .centerX
        tile.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
        card.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(cardClicked(_:))))
        cards.append((theme, tile))
        card.setAccessibilityLabel(theme.title)
        card.setAccessibilityRole(.button)
        return card
    }

    @objc private func cardClicked(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view,
              let index = cards.firstIndex(where: { $0.tile.isDescendant(of: view) }) else { return }
        UserDefaults.standard.set(cards[index].theme.rawValue, forKey: Self.themeKey)
    }

    // MARK: Editor

    private func buildEditor() {
        let labels = [L("Background"), L("Text"), L("Selection keys"), L("Highlighted row")]
        linked.onAction { [weak self] in
            guard let self else { return }
            var colors = ThemeColors(text: self.customText)
            colors.setLinked(self.linked.state == .on, keeping: self.dark)
            self.customText = colors.text
        }
        var rows: [NSView] = [
            UI.hstack([linked, UI.label(L("Same colors in light and dark"))]),
            scopeNote,
        ]
        for slot in 0..<ThemeColors.slotCount {
            let well = NSColorWell(style: .minimal)
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            well.onAction { [weak self, weak well] in
                guard let self, let well else { return }
                self.setSlot(slot, ThemeColors.hexString(well.color.rgb))
            }
            let field = NSTextField(string: "")
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: 96).isActive = true
            field.onTextChange { [weak self, weak field] in
                guard let self, let field else { return }
                self.setSlot(slot, field.stringValue)
            }
            let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                     accessibilityDescription: nil) ?? NSImage())
            warning.contentTintColor = .systemOrange
            warning.toolTip = L("Not a hex color; the default is used.")
            wells.append(well)
            fields.append(field)
            warnings.append(warning)
            let name = UI.label(labels[slot])
            name.widthAnchor.constraint(equalToConstant: 110).isActive = true
            rows.append(UI.hstack([name, well, field, warning], spacing: 10))
        }
        let start = NSPopUpButton(frame: .zero, pullsDown: true)
        start.addItem(withTitle: L("Start from…"))
        for preset in [PanelTheme.solarized, .nord, .gruvbox, .catppuccin] {
            start.addItem(withTitle: preset.title)
            start.lastItem?.representedObject = preset.rawValue
        }
        start.onAction { [weak self, weak start] in
            guard let self, let raw = start?.selectedItem?.representedObject as? String,
                  let preset = PanelTheme(rawValue: raw),
                  let light = preset.palette(dark: false), let night = preset.palette(dark: true) else { return }
            self.customText = ThemeColors(light: light.colors.map(\.rgb), dark: night.colors.map(\.rgb)).text
            self.message.stringValue = ""
        }
        let copy = UI.button(L("Copy")) { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.customText, forType: .string)
            self.message.stringValue = L("Copied the theme text.")
        }
        let paste = UI.button(L("Paste")) { [weak self] in
            guard let self else { return }
            let pasted = NSPasteboard.general.string(forType: .string) ?? ""
            if let parsed = ThemeColors(strict: pasted) {
                self.customText = parsed.text
                self.message.stringValue = L("Pasted the theme.")
            } else {
                NSSound.beep()
                self.message.stringValue = L("The clipboard does not hold a theme: four hex colors, or two such lists separated by |.")
            }
        }
        let reset = UI.button(L("Reset")) { [weak self] in
            self?.customText = CustomTheme.defaultText
            self?.message.stringValue = ""
        }
        rows.append(UI.hstack([start, copy, paste, reset]))
        rows.append(message)
        let controls = UI.vstack(rows, spacing: 10)

        bigSketch.width = 150
        bigSketch.setContentHuggingPriority(.required, for: .horizontal)
        editor.orientation = .horizontal
        editor.alignment = .top
        editor.spacing = 24
        editor.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        editor.addArrangedSubview(controls)
        editor.addArrangedSubview(bigSketch)
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 12
    }

    private func setSlot(_ slot: Int, _ value: String) {
        var colors = ThemeColors(text: customText)
        colors.set(slot, dark: dark, to: value)
        customText = colors.text
    }

    // MARK: Rendering

    private func render() {
        let isDark = dark
        segments.selectedSegment = isDark ? 1 : 0
        let custom = CustomTheme(text: customText)
        var small = MisstypePrefs.panelStyle
        small.fontSize = 12
        for card in cards {
            card.tile.sketch.style = small
            card.tile.sketch.forceDark = isDark
            card.tile.sketch.palette = card.theme.palette(dark: isDark, custom: custom)
            card.tile.selected = card.theme == themeValue
        }
        editor.isHidden = themeValue != .custom
        guard themeValue == .custom else { return }
        editor.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        let colors = custom.colors
        linked.state = colors.linked ? .on : .off
        scopeNote.stringValue = colors.linked ? L("Edits apply to light and dark.")
            : isDark ? L("Editing the dark colors.") : L("Editing the light colors.")
        for slot in 0..<ThemeColors.slotCount {
            let rgb = colors.resolved(slot, dark: isDark)
            if wells[slot].color.rgb != rgb { wells[slot].color = NSColor(rgb: rgb) }
            // A hex field being typed in keeps its text while the rest redraws.
            if fields[slot].currentEditor() == nil { fields[slot].stringValue = colors.hex(slot, dark: isDark) }
            warnings[slot].isHidden = colors.isValid(slot, dark: isDark)
        }
        bigSketch.style = MisstypePrefs.panelStyle
        bigSketch.forceDark = isDark
        bigSketch.palette = custom.palette(dark: isDark)
    }
}
