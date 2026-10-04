import Cocoa

/// Double-click installer shipped in the DMG. `--yes` skips the dialogs and
/// prints the outcome (scripted installs, release smoke tests).
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quiet = CommandLine.arguments.contains("--yes")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.terminate(nil) }

        guard let payload = Install.payload, let new = Install.version(of: payload) else {
            return fail(Install.Failure("The installer is missing its payload. Download Misstype again."))
        }
        if !quiet, !confirm(new: new) { return }
        do {
            report(try Install.run())
        } catch {
            fail(error)
        }
    }

    private func confirm(new: Install.Version) -> Bool {
        let alert = makeAlert()
        if let old = Install.version(of: Install.destination) {
            alert.messageText = L("Update Misstype to %@?", new.short)
            alert.informativeText = L("Version %@ is installed. Your settings and learned phrases are kept.", old.short)
            alert.addButton(withTitle: L("Update"))
        } else {
            alert.messageText = L("Install Misstype %@", new.short)
            alert.informativeText = L("This installs the Misstype input method for your account. No administrator password is needed.")
            alert.addButton(withTitle: L("Install"))
        }
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func report(_ outcome: Install.Outcome) {
        var warning = ""
        if let copy = Install.systemCopy {
            warning = "\n\n" + L("An older system-wide copy exists at %@. Remove it, or two Misstype entries will appear.", copy.path)
        }
        let title: String, detail: String
        switch outcome {
        case .needsLogout:
            title = L("Misstype is installed")
            detail = L("macOS lists a new input method only after you log in again. Log out and back in once, then add Misstype in System Settings › Keyboard › Input Sources.")
        case .ready:
            title = L("Misstype is installed")
            detail = L("Open System Settings › Keyboard › Input Sources, press +, and add Misstype.")
        case .updated(let version):
            title = L("Misstype was updated")
            detail = L("Now version %@. The new version starts the next time you type.", version.short)
        }
        if quiet {
            print("\(title): \(detail)\(warning)")
            return
        }
        let alert = makeAlert()
        alert.messageText = title
        alert.informativeText = detail + warning
        switch outcome {
        case .needsLogout:
            alert.addButton(withTitle: L("Log Out…"))
            alert.addButton(withTitle: L("Later"))
            if alert.runModal() == .alertFirstButtonReturn, !Install.requestLogout() {
                let manual = makeAlert()
                manual.messageText = L("Couldn't log out automatically")
                manual.informativeText = L("Choose Apple menu › Log Out.")
                manual.runModal()
            }
        case .ready:
            alert.addButton(withTitle: L("Open Keyboard Settings"))
            alert.addButton(withTitle: L("Done"))
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        case .updated:
            alert.addButton(withTitle: L("Done"))
            alert.runModal()
        }
    }

    private func fail(_ error: Error) {
        if quiet {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
        let alert = makeAlert()
        alert.alertStyle = .critical
        alert.messageText = L("Installation failed")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("Quit"))
        alert.runModal()
    }

    private func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.icon = Bundle.main.image(forResource: "MistypeIcon")
        return alert
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
