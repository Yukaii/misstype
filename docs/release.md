# Packaging, installer and updates (macOS)

Status 2026-10-04: written on Linux, first run on a Mac the same day; see
"Verification status" and "Unverified" below for what has and has not been
checked.

## Decisions

| Question | Choice | Why |
|---|---|---|
| Install location | `~/Library/Input Methods/MistypeIME.app`, per user | No admin password at install, and the bundle stays user-writable so Sparkle updates in place without an authorization prompt on every release. McBopomofo and vChewing install this way; Squirrel, ChiaKey and KeyKey use a system `.pkg` and `/Library/Input Methods`. |
| Installer | `Install Misstype.app` inside a DMG (`MistypeInstaller` target) | Same steps as `script/install_ime.sh`, double-clickable, localized (en/zh-Hant/zh-Hans/ja). The IME is copied by our own process, so the installed copy carries no quarantine flag. |
| Updates | Sparkle 2 in the IME, feed on GitHub Releases | Industry standard, EdDSA-signed archives independent of Apple signing. |

## Sandbox interaction

The IME is sandboxed (`Resources/Mistype.entitlements`, architecture.md).
For Sparkle that means: `Installer.xpc` stays in the bundle and is signed
by `sign_bundle.sh`, `Downloader.xpc` is removed (the app already holds
`network.client`), `SUEnableInstallerLauncherService` is on, and the
entitlements add the `mach-lookup` exceptions `<bundle id>-spki` / `-spks`.
The installer app itself is **not** sandboxed (it must write to the real
`~/Library/Input Methods`); the IME's user data lives in its container, so
an uninstaller would have to clear
`~/Library/Containers/org.mistype.inputmethod.Mistype`.

## What the installer does

1. Copies the bundled `MistypeIME.app` next to the target, stops a running
   copy (terminate, then force), swaps it in atomically.
2. `lsregister -f`, restarts `TextInputMenuAgent`/`TextInputSwitcher`.
3. `TISRegisterInputSource`; on a **first install** also enables the sources.
   Updates never re-enable a source the user removed.
4. If TIS does not list the source yet (the normal case for a brand-new input
   method), it says so and offers **Log Out…** — macOS only shows a new input
   method after the next login. Otherwise it offers to open Keyboard
   settings. It never launches the IME by hand (see `install_ime.sh`).

`Install Misstype.app --yes` skips the dialogs and prints the outcome.
It warns when an older `/Library/Input Methods/MistypeIME.app` exists.

## Updates

- `SUFeedURL` is `https://github.com/Yukaii/misstype/releases/latest/download/appcast.xml`;
  every release uploads an `appcast.xml` with only its own item, GitHub
  serves the newest non-prerelease's copy.
- Scheduled checks download silently (`SUAutomaticallyUpdate`). The update is
  applied by `UpdateController` only after 120 s without keys and with
  nothing composed, then the IME exits; TIS restarts it on demand
  (`updaterShouldRelaunchApplication` is false on purpose). A client that
  was mid-session may need a refocus before it reconnects.
- Settings ▸ About ▸ Updates: automatic-check toggle and a manual check (the
  only path that shows Sparkle's window, so a scheduled update never steals
  focus from the text field).
- The updater starts only when the bundle has `SUPublicEDKey`; development
  builds never contact the network. The request carries the app and macOS
  versions (`SUEnableSystemProfiling` is off), never typed text.
- `CFBundleVersion` must increase every release (CI uses the run number).

## One-time setup (maintainer)

1. Find Sparkle's tools after a build: `.build/artifacts/sparkle/Sparkle/bin/`.
2. `generate_keys` creates the key pair in your login keychain and prints the
   public key. Put it in `Resources/SparklePublicKey.txt` and commit it.
3. `generate_keys -x sparkle_private.key` exports the private key; store its
   content as the repo secret `SPARKLE_ED_PRIVATE_KEY`, then delete the file.
   Losing it means existing installs can never update (they would need a
   manual reinstall carrying a new public key).
4. Optional but recommended: Developer ID + notary secrets listed at the top
   of `.github/workflows/release.yml`. Without them the DMG is ad-hoc signed
   and Gatekeeper blocks opening it on other Macs until
   `xattr -dr com.apple.quarantine`.

## Cutting a release

```sh
git tag v0.2.0 && git push origin v0.2.0      # CI: test, package, publish
./script/package_release.sh 0.2.0             # same thing locally, into dist/
```

Artifacts: `Misstype-<v>.dmg`, `MistypeIME-<v>.zip` (the Sparkle archive),
`appcast.xml`, `.sha256` files. Tags containing `-` are prereleases and are
skipped by `latest`, so they never reach existing installs.

## Verification status

Verified 2026-10-04 on macOS 27 (arm64 host, ad-hoc signed, local feed on
`http://localhost:8000` with a throwaway EdDSA key):

- `swift build` resolves Sparkle; the bundle runs; IME, installer and Sparkle
  are universal (`x86_64 arm64`).
- A sandboxed IME updates itself in place: `Installer.xpc` launches and the
  `-spki`/`-spks` mach-lookup exceptions are enough. Silent download, idle
  apply after 120 s, TIS restart, 0.0.4 → 0.0.5, signature valid afterwards.
  `immediateInstallationBlock` alone did **not** quit the `LSUIElement` app
  (Autoupdate waited forever), so `UpdateController` terminates the process
  itself 3 s after calling it. Scheduled checks respect `SULastCheckTime`
  (24 h), so repeating a test needs that key removed from the container prefs.
- First install on a clean account (`--yes` and GUI): the source was usable
  **without logging out** on this macOS. The logout path is kept as the
  fallback; it is untested here.
- Upgrading over a copy installed by `install_ime.sh` (headless).
- Updates are refused when they should be: a zip with one flipped byte under a
  valid appcast signature, and an intact zip signed with a different key, both
  abort with `SUSparkleErrorDomain 4005` and leave the installed version alone.
- Signing and notarization through `release.yml` (`workflow_dispatch`,
  `0.0.1-rc1`, no release published): the DMG, the installer and the embedded
  IME are signed with the Developer ID Application certificate, hardened
  runtime on, notarized (`spctl`: `Notarized Developer ID`), DMG and IME
  stapled; universal; sandbox entitlements and `Installer.xpc` present; the
  production Sparkle public key and the GitHub feed URL are embedded; a
  quarantined copy of the DMG is accepted by Gatekeeper.
- A process TIS launched while the installer was swapping the bundle never
  started its updater (`.MistypeIME.installing` path); restarting it fixed
  it. Not reproduced on purpose; watch for it.

## Unverified (check before the first public release)

- Notarization on a **different** Mac with a real browser download (the DMG
  was only checked here with a simulated quarantine flag).
- `System Events` log-out request (Automation prompt wording); the first
  install needed no logout on macOS 27, so this path may be hard to reach.
- The `/Library/Input Methods` duplicate warning in the GUI.
- Installing an older version over a newer one (the installer does not warn).
- `CFBundleVersion` comes from the workflow run number; make sure it stays
  above any build already shipped.

## Not done

- Uninstaller (remove the bundle, `MistypeSourceTool disable`, optionally the
  user data under the container).
- Delta updates, release channels, downgrade protection beyond Sparkle's
  build-number comparison.
- Linux packaging (see `docs/linux-port.md` L4).
