import Cocoa
@preconcurrency import Carbon

/// Per-user install of the bundled `MisstypeIME.app` into
/// `~/Library/Input Methods` (no administrator password; the same location
/// Sparkle later updates in place). Mirrors `script/install_ime.sh`.
enum Install {
    static let bundleID = "org.misstype.inputmethod.Misstype"
    static let appName = "MisstypeIME.app"

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct Version {
        let short: String
        let build: String
    }

    enum Outcome {
        /// Fresh install and macOS does not list the input method yet.
        case needsLogout
        /// Fresh install, input method registered and enabled.
        case ready
        case updated(Version)
    }

    static var payload: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(appName)
    }

    static var destination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods").appendingPathComponent(appName)
    }

    /// An older system-wide install would shadow or duplicate the new one.
    static var systemCopy: URL? {
        let url = URL(fileURLWithPath: "/Library/Input Methods").appendingPathComponent(appName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func version(of app: URL) -> Version? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return Version(short: info["CFBundleShortVersionString"] as? String ?? "?",
                       build: info["CFBundleVersion"] as? String ?? "?")
    }

    static func run() throws -> Outcome {
        guard let payload, FileManager.default.fileExists(atPath: payload.path) else {
            throw Failure("The installer is missing its payload (\(appName)). Download Misstype again.")
        }
        let fresh = !FileManager.default.fileExists(atPath: destination.path)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // Copy beside the target first so a failed copy never leaves the user
        // without an input method; the swap itself is atomic.
        let staging = parent.appendingPathComponent(".MisstypeIME.installing")
        try? FileManager.default.removeItem(at: staging)
        try tool("/usr/bin/ditto", [payload.path, staging.path])
        stopRunningIME()
        if fresh {
            try FileManager.default.moveItem(at: staging, to: destination)
        } else {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        }

        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        try? tool(lsregister, ["-f", destination.path])
        // Menu-bar agents cache the source list; same refresh install_ime.sh does.
        try? tool("/usr/bin/killall", ["TextInputMenuAgent", "TextInputSwitcher"])

        let visible = registerSource(enable: fresh)
        if !fresh, let version = version(of: destination) { return .updated(version) }
        return visible ? .ready : .needsLogout
    }

    /// Never launch the IME by hand: TIS starts it on demand, and a manual
    /// copy would squat its Mach service (see install_ime.sh).
    private static func stopRunningIME() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    /// Registers the bundle with TIS and, on first install, enables its
    /// sources. Returns whether TIS lists them; a brand-new input method
    /// usually only appears after the next login.
    private static func registerSource(enable: Bool) -> Bool {
        _ = TISRegisterInputSource(destination as CFURL)
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else { return false }
        var found = false
        for source in list {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
            guard id == bundleID || id.hasPrefix(bundleID + ".") else { continue }
            found = true
            // An update must not re-add a source the user removed.
            if enable { TISEnableInputSource(source) }
        }
        return found
    }

    @discardableResult
    private static func tool(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure("\((path as NSString).lastPathComponent) failed: \(text)")
        }
        return text
    }

    /// Asks macOS to log out (it shows its own confirmation). Needs the
    /// one-time Automation prompt; returns false when that is declined.
    static func requestLogout() -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to log out")?.executeAndReturnError(&error)
        return error == nil
    }
}
