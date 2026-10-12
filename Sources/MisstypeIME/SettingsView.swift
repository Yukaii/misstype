import Cocoa
import MisstypeMacKit

/// Settings window: a source-list sidebar and one pane per topic, plain
/// AppKit (`SettingsKit.swift` has the layout helpers, `SettingsPanes*.swift`
/// the panes). Controls bind straight to the `Misstype*` UserDefaults keys
/// that `MisstypePrefs` reads per keystroke, so a change applies on the next
/// key and `defaults write` shows up here live.
final class SettingsWindow: NSWindow {
    static let shared = SettingsWindow()

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = L("Misstype Settings")
        isReleasedWhenClosed = false
        contentMinSize = NSSize(width: 660, height: 440)
        // An empty toolbar gives the unified titlebar: the sidebar runs under
        // it with inline traffic lights and the title sits over the pane.
        toolbar = NSToolbar(identifier: "MisstypeSettings")
        toolbarStyle = .unified
        isMovableByWindowBackground = true
        contentViewController = SettingsSplitViewController()
        setContentSize(NSSize(width: 760, height: 640))
        setFrameAutosaveName("MisstypeSettingsWindow2")
        if !setFrameUsingName("MisstypeSettingsWindow2") { center() }
    }

    /// The IME process has no main menu, so nothing owns ⌘A/C/X/V/Z and text
    /// fields (the dictionary editor above all) would beep. After the normal
    /// handling, send the standard edit action down the responder chain.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = flags.contains(.shift)
        let action: Selector?
        switch key {
        case "a" where !shift: action = #selector(NSText.selectAll(_:))
        case "c" where !shift: action = #selector(NSText.copy(_:))
        case "x" where !shift: action = #selector(NSText.cut(_:))
        case "v" where !shift: action = #selector(NSText.paste(_:))
        case "z": action = Selector(shift ? "redo:" : "undo:")
        default: action = nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
    }
}

enum SettingsTopic: Int, CaseIterable {
    case general, appearance, shortcuts, decoding, learning, dictionary, about

    var title: String {
        switch self {
        case .general: return L("General")
        case .appearance: return L("Appearance")
        case .shortcuts: return L("Shortcuts")
        case .decoding: return L("Decoding")
        case .learning: return L("Learning")
        case .dictionary: return L("My Dictionary")
        case .about: return L("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .shortcuts: return "keyboard"
        case .decoding: return "wand.and.stars"
        case .learning: return "book.closed"
        case .dictionary: return "character.book.closed"
        case .about: return "info.circle"
        }
    }

    /// Icon tile color, as in System Settings.
    var tint: NSColor {
        switch self {
        case .general, .about: return .systemGray
        case .appearance: return .systemBlue
        case .shortcuts: return .systemIndigo
        case .decoding: return .systemPurple
        case .learning: return .systemGreen
        case .dictionary: return .systemOrange
        }
    }

    func makePane() -> SettingsPane {
        switch self {
        case .general: return GeneralPane()
        case .appearance: return AppearancePane()
        case .shortcuts: return ShortcutsPane()
        case .decoding: return DecodingPane()
        case .learning: return LearningPane()
        case .dictionary: return DictionaryPane()
        case .about: return AboutPane()
        }
    }
}

// MARK: - Split view

final class SettingsSplitViewController: NSSplitViewController {
    private let sidebar = SettingsSidebarController()
    private let content = SettingsContentController()
    private var language = UserDefaults.standard.string(forKey: UILanguage.userDefaultsKey) ?? ""
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 190
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: content))
        sidebar.onSelect = { [weak self] topic in
            self?.content.show(topic)
            self?.view.window?.title = topic.title
        }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.languageMayHaveChanged()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.title = sidebar.selected.title
    }

    /// L() is read while building, so a language change rebuilds everything.
    private func languageMayHaveChanged() {
        let code = UserDefaults.standard.string(forKey: UILanguage.userDefaultsKey) ?? ""
        guard code != language else { return }
        language = code
        view.window?.title = sidebar.selected.title
        sidebar.reload()
        content.reloadAll()
    }
}

// MARK: - Sidebar

final class SettingsSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    var onSelect: (SettingsTopic) -> Void = { _ in }
    private(set) var selected = SettingsTopic.general

    override func loadView() {
        let column = NSTableColumn(identifier: .init("topic"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .large
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let info = Bundle.main.infoDictionary
        let footer = NSTextField(labelWithString: "v\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
        footer.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        footer.textColor = .tertiaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scroll)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
        table.selectRowIndexes([selected.rawValue], byExtendingSelection: false)
    }

    func reload() {
        table.reloadData()
        table.selectRowIndexes([selected.rawValue], byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { SettingsTopic.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let topic = SettingsTopic.allCases[row]
        let cell = NSTableCellView()
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 6
        tile.layer?.backgroundColor = topic.tint.cgColor
        tile.translatesAutoresizingMaskIntoConstraints = false
        let image = NSImageView(image: NSImage(systemSymbolName: topic.symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = .white
        image.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        image.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(image)
        let text = NSTextField(labelWithString: topic.title)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tile)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            tile.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 24),
            tile.heightAnchor.constraint(equalToConstant: 24),
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let topic = SettingsTopic(rawValue: table.selectedRow) else { return }
        selected = topic
        onSelect(topic)
    }
}

// MARK: - Content

/// Hosts the selected pane; panes are built once and kept (scroll position,
/// unsaved dictionary text) until the language changes.
final class SettingsContentController: NSViewController {
    private var panes: [SettingsTopic: SettingsPane] = [:]
    private var current: SettingsPane?

    override func loadView() {
        view = NSView()
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        show(.general)
    }

    func show(_ topic: SettingsTopic) {
        let pane = panes[topic] ?? topic.makePane()
        panes[topic] = pane
        guard pane !== current else { return }
        if let current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(pane)
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.topAnchor.constraint(equalTo: view.topAnchor),
            pane.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pane.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        current = pane
    }

    func reloadAll() {
        for pane in panes.values where pane.isViewLoaded { pane.reload() }
    }
}
