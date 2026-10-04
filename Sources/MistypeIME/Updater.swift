import Cocoa
import Sparkle

/// Sparkle wrapper. An input method must never steal focus or die while the
/// user is typing, so scheduled updates are downloaded silently
/// (`SUAutomaticallyUpdate`) and applied only once the session has been idle
/// and uncomposed for a while; the app is not relaunched by Sparkle — TIS
/// restarts the IME on demand, as after `install_ime.sh` (a hand-launched
/// copy would squat the Mach service). A user-initiated check from Settings
/// shows Sparkle's normal window.
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

    nonisolated func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { false }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Runtime.debugLog("[update] aborted: \((error as NSError).domain) \((error as NSError).code)")
    }
}
