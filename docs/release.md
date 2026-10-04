# Packaging, installer and updates (macOS)

Status 2026-10-04: written and reviewed on Linux only. **Nothing here has run
on a Mac yet**; the "Unverified" list below is the first-run checklist.

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

- `SUFeedURL` is `https://github.com/Yukaii/mistype/releases/latest/download/appcast.xml`;
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

## Unverified (check on a Mac before the first public release)

- `swift build` resolves Sparkle and `MistypeIME` runs from the bundle
  (rpath `@executable_path/../Frameworks`), also with `--arch arm64 --arch x86_64`
  (location of `Sparkle.framework` and `sign_update` in `.build`).
- The inside-out signing in `script/sign_bundle.sh` passes notarization with
  Sparkle's `Autoupdate`, `Updater.app` and `Installer.xpc` re-signed, the
  entitlements applied to the app only.
- A sandboxed IME actually updates itself in place: `Installer.xpc` launches
  and the `-spki`/`-spks` mach-lookup exceptions are enough (Sparkle's
  sandboxing guide is the reference if not).
- First install on a clean account: source absent → logout prompt → after
  login the source is listed. Whether `TISRegisterInputSource` makes it
  visible without logout on current macOS.
- `System Events` log-out request (Automation prompt wording).
- Full update loop with two real builds: silent download, idle apply,
  TIS restart, clients reconnecting.
- Upgrading over a copy installed by `install_ime.sh`.

## Not done

- Uninstaller (remove the bundle, `MistypeSourceTool disable`, optionally the
  user data under the container).
- Delta updates, release channels, downgrade protection beyond Sparkle's
  build-number comparison.
- Linux packaging (see `docs/linux-port.md` L4).
