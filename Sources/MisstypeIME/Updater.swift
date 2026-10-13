import Cocoa
import Sparkle

/// Sparkle wrapper. An input method must never steal focus or die while the
/// user is typing, so scheduled updates are downloaded silently
/// (`SUAutomaticallyUpdate`) and applied only once the session has been idle
/// and uncomposed for a while; the process quits itself for the installer and
/// TIS (or Sparkle) restarts it, as after `install_ime.sh`. A user-initiated
/// check from Settings shows Sparkle's normal window.
///
/// The updater only starts when the bundle carries `SUFeedURL` and a
/// `SUPublicEDKey` (injected by `script/package_release.sh`), so development
/// builds never touch the network. The request is Sparkle's appcast fetch
/// (app version, macOS version, no system profile) — never typed text.
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    /// How long without keys (and with nothing composed) before a downloaded
    /// update is applied.
    private static let idleBeforeInstall: TimeInterval = 120

    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private var lastKey = Date()
    private var timer: Timer?
    private var composing = false

    var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let key = info?["SUPublicEDKey"] as? String ?? ""
        let feed = info?["SUFeedURL"] as? String ?? ""
        return !key.isEmpty && !feed.isEmpty
    }

    var updater: SPUUpdater? { controller?.updater }
    var updateReady: Bool { installNow != nil }

    func start() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateController.shared.installIfIdle() }
        }
        Runtime.debugLog("[update] updater started")
    }

    /// Called from the IMK adapter, which runs on the main thread but is not
    /// annotated as such.
    nonisolated static func noteKey(composing: Bool) {
        MainActor.assumeIsolated {
            shared.lastKey = Date()
            shared.composing = composing
        }
    }

    nonisolated static func setComposing(_ composing: Bool) {
        MainActor.assumeIsolated { shared.composing = composing }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    private func installIfIdle() {
        guard let installNow, !composing,
              Date().timeIntervalSince(lastKey) > Self.idleBeforeInstall else { return }
        Runtime.debugLog("[update] applying downloaded update while idle")
        self.installNow = nil
        installNow()
        quitForInstall()
    }

    /// Autoupdate swaps the bundle once this process is gone. Measured on
    /// macOS 27: neither the immediate-install block nor Sparkle's own
    /// "Install" button quits an LSUIElement input method, so the install
    /// would wait forever (seen 2026-10-12: Autoupdate parked for 1h44m).
    /// TIS restarts us on demand.
    ///
    /// `NSApp.terminate` alone was not enough: 0.4.10 → 0.5.0 (2026-10-13)
    /// still parked until `pkill -x MisstypeIME`, so if the process is still
    /// here shortly after `terminate`, exit directly. Nothing is pending at
    /// that point: learned phrases are written when learned.
    private var quitScheduled = false
    private func quitForInstall() {
        guard !quitScheduled else { return }
        quitScheduled = true
        Runtime.debugLog("[update] quitting so the installer can swap the bundle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Runtime.debugLog("[update] terminate")
            NSApp.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Runtime.debugLog("[update] still running after terminate; exiting")
                exit(0)
            }
        }
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater,
                             willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        Task { @MainActor in
            Runtime.debugLog("[update] \(version) downloaded; waiting for an idle moment")
            self.installNow = immediateInstallationBlock
        }
        return true
    }

    /// Fires on every path that starts an install — the idle apply above and
    /// the "Install" button in Sparkle's window from Settings.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Task { @MainActor in self.quitForInstall() }
    }

    /// Must stay `true`: Sparkle's `installWithToolAndRelaunch` aborts silently
    /// when this returns `false`, so Settings ▸ Install did nothing and
    /// `willInstallUpdate` never fired (2026-10-13, 0.4.10 → 0.5.0). Sparkle
    /// then relaunches the swapped bundle from its installed path, the same
    /// copy TIS would start.
    nonisolated func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { true }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Runtime.debugLog("[update] aborted: \((error as NSError).domain) \((error as NSError).code)")
    }
}
