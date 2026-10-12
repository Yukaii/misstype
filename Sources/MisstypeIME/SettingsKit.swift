import Cocoa
import ObjectiveC

/// Layout and binding helpers for the AppKit Settings window. Panes are
/// vertical stacks of grouped "cards" (rows of label + control), built in
/// code; there is no Form to mis-measure rows, so every size is explicit.

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Closure targets

private final class ActionTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

private var actionTargetKey: UInt8 = 0
private var textObserverKey: UInt8 = 0

extension NSControl {
    /// Replaces target/action with a closure the control keeps alive.
    func onAction(_ handler: @escaping () -> Void) {
        let target = ActionTarget(handler)
        objc_setAssociatedObject(self, &actionTargetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        self.target = target
        action = #selector(ActionTarget.fire)
    }
}

extension NSTextField {
    /// Calls `handler` on every edit (not only on Return).
    func onTextChange(_ handler: @escaping () -> Void) {
        let token = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification, object: self, queue: .main) { _ in handler() }
        objc_setAssociatedObject(self, &textObserverKey, TokenBox(token), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

private final class TokenBox {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

// MARK: - Labels

enum UI {
    static func label(_ text: String, size: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// Small secondary text that wraps at `width`.
    static func caption(_ text: String, width: CGFloat = 440, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = color
        field.preferredMaxLayoutWidth = width
        field.isSelectable = false
        return field
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func button(_ title: String, role: NSButton.BezelStyle = .rounded, _ handler: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = role
        button.controlSize = .small // button rows read lighter small, as in System Settings
        button.onAction(handler)
        return button
    }
}

// MARK: - Card

/// Rounded grouped container with separators between rows, filled with the
/// label color at 5% alpha (resolved per appearance in `updateLayer`).
final class CardView: NSView {
    private let stack = NSStackView()

    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                stack.addArrangedSubview(line)
                line.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14).isActive = true
                line.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Translucent fill (not an opaque card) so the window's glass shows through.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
    }
}

// MARK: - Pane base

/// A settings pane: a scroll view over a vertical stack of groups. Subclasses
/// implement `build()` (called again on `reload()`, e.g. a language change)
/// and register `refreshers` that pull state from UserDefaults, which run
/// after every defaults change so `defaults write` shows up live.
class SettingsPane: NSViewController {
    static let contentWidth: CGFloat = 520

    private let stack = NSStackView()
    private var refreshers: [() -> Void] = []
    private var observer: NSObjectProtocol?

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = true
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -20),
        ])
        let preferred = stack.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        preferred.priority = .defaultHigh
        preferred.isActive = true
        view = scroll
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Override: add groups with `group`.
    func build() {}

    /// Override: state outside UserDefaults to re-read when the pane shows.
    func paneWillShow() {}

    override func viewWillAppear() {
        super.viewWillAppear()
        paneWillShow()
        refresh()
    }

    func reload() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        refreshers = []
        build()
        refresh()
    }

    func refresh() { refreshers.forEach { $0() } }

    func onRefresh(_ handler: @escaping () -> Void) { refreshers.append(handler) }

    // MARK: Groups and rows

    /// A titled card of rows, with an optional trailing header view and footer.
    func group(_ title: String? = nil, headerAccessory: NSView? = nil, footer: String? = nil, rows: [NSView]) {
        var parts: [NSView] = []
        if title != nil || headerAccessory != nil {
            let heading = UI.label(title ?? "", size: NSFont.systemFontSize, weight: .semibold)
            let header = UI.hstack([heading] + (headerAccessory.map { [spacer(), $0] } ?? []))
            header.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
            parts.append(header)
        }
        parts.append(CardView(rows: rows))
        if let footer {
            let note = UI.caption(footer, width: Self.contentWidth - 16)
            let inset = UI.hstack([note])
            inset.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
            parts.append(inset)
        }
        let box = UI.vstack(parts, spacing: 6)
        stack.addArrangedSubview(box)
        for part in parts { part.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true }
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    /// Label (and optional explanation) on the left, control pinned to the
    /// trailing edge. Not a stack: a stack leaves the control wherever the
    /// text column happened to end, so controls would not line up between rows.
    func row(_ title: String, detail: String? = nil, control: NSView) -> NSView {
        if control is NSPopUpButton {
            control.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        }
        // The caption wraps to what is left beside the control.
        let inner = Self.contentWidth - 32
        let controlWidth = min(control.fittingSize.width, 240)
        let textWidth = max(inner - 16 - controlWidth, 180)

        let text = UI.vstack([UI.label(title)], spacing: 2)
        if let detail { text.addArrangedSubview(UI.caption(detail, width: textWidth)) }
        text.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let container = NSView()
        for view in [text, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            text.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            text.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 8),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return container
    }

    /// Full-width content under an optional title/explanation.
    func block(_ title: String? = nil, detail: String? = nil, content: NSView) -> NSView {
        var parts: [NSView] = []
        if let title { parts.append(UI.label(title)) }
        if let detail { parts.append(UI.caption(detail, width: Self.contentWidth - 28)) }
        parts.append(content)
        let stack = UI.vstack(parts, spacing: 6)
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return padded(stack)
    }

    private func padded(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return container
    }

    // MARK: Bound controls

    func switchControl(key: String) -> NSSwitch {
        let control = NSSwitch()
        control.onAction { UserDefaults.standard.set(control.state == .on, forKey: key) }
        onRefresh {
            let on = UserDefaults.standard.bool(forKey: key)
            if (control.state == .on) != on { control.state = on ? .on : .off }
        }
        return control
    }

    func toggleRow(_ title: String, detail: String? = nil, key: String) -> NSView {
        row(title, detail: detail, control: switchControl(key: key))
    }

    /// Segmented control over string values stored under `key` (a few
    /// mutually exclusive choices read better inline than hidden in a menu).
    func segmented(key: String, options: [(title: String, value: String)]) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: options.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        control.segmentStyle = .rounded
        control.onAction {
            guard options.indices.contains(control.selectedSegment) else { return }
            UserDefaults.standard.set(options[control.selectedSegment].value, forKey: key)
        }
        onRefresh {
            let value = UserDefaults.standard.string(forKey: key) ?? ""
            let index = options.firstIndex { $0.value == value } ?? 0
            if control.selectedSegment != index { control.selectedSegment = index }
        }
        return control
    }

    /// Pop-up over string values stored under `key`. `extra` adds a value
    /// that is stored but not listed (an uninstalled font) so nothing blanks.
    func popup(key: String, options: [(title: String, value: String)], separatorAfter: Int? = nil) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        func fill(_ extra: String?) {
            popup.removeAllItems()
            var all = options
            if let extra, !extra.isEmpty, !options.contains(where: { $0.value == extra }) {
                all.insert((extra, extra), at: min(1, all.count))
            }
            for (index, option) in all.enumerated() {
                popup.addItem(withTitle: option.title)
                popup.lastItem?.representedObject = option.value
                if index == separatorAfter { popup.menu?.addItem(.separator()) }
            }
        }
        fill(nil)
        popup.onAction {
            if let value = popup.selectedItem?.representedObject as? String {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        onRefresh {
            let value = UserDefaults.standard.string(forKey: key) ?? ""
            if !popup.itemArray.contains(where: { $0.representedObject as? String == value }) { fill(value) }
            if let item = popup.itemArray.first(where: { $0.representedObject as? String == value }),
               popup.selectedItem !== item {
                popup.select(item)
            }
        }
        return popup
    }

    /// Slider over a Double stored under `key`, with a value label.
    func sliderControl(key: String, range: ClosedRange<Double>, format: @escaping (Double) -> String,
                       read: @escaping () -> Double) -> NSView {
        let slider = NSSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: nil, action: nil)
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let value = UI.label("", color: .secondaryLabelColor)
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 48).isActive = true
        slider.onAction {
            let rounded = slider.doubleValue.rounded()
            UserDefaults.standard.set(rounded, forKey: key)
            value.stringValue = format(rounded)
        }
        onRefresh {
            let current = read()
            if slider.doubleValue != current { slider.doubleValue = current }
            value.stringValue = format(current)
        }
        return UI.hstack([slider, value])
    }
}
