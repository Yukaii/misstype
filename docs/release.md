# Packaging, installer and updates (macOS)

Status 2026-10-04: written on Linux, first run on a Mac the same day; see
"Verification status" and "Unverified" below for what has and has not been
checked.

## Decisions

| Question | Choice | Why |
|---|---|---|
| Install location | `~/Library/Input Methods/MisstypeIME.app`, per user | No admin password at install, and the bundle stays user-writable so Sparkle updates in place without an authorization prompt on every release. McBopomofo and vChewing install this way; Squirrel, ChiaKey and KeyKey use a system `.pkg` and `/Library/Input Methods`. |
| Installer | `Install Misstype.app` inside a DMG (`MisstypeInstaller` target) | Same steps as `script/install_ime.sh`, double-clickable, localized (en/zh-Hant/zh-Hans/ja). The IME is copied by our own process, so the installed copy carries no quarantine flag. |
| Updates | Sparkle 2 in the IME, feed on GitHub Releases | Industry standard, EdDSA-signed archives independent of Apple signing. |

## Sandbox interaction

The IME is sandboxed (`Resources/Misstype.entitlements`, architecture.md).
For Sparkle that means: `Installer.xpc` stays in the bundle and is signed
by `sign_bundle.sh`, `Downloader.xpc` is removed (the app already holds
`network.client`), `SUEnableInstallerLauncherService` is on, and the
entitlements add the `mach-lookup` exceptions `<bundle id>-spki` / `-spks`.
The installer app itself is **not** sandboxed (it must write to the real
`~/Library/Input Methods`); the IME's user data lives in its container, so
an uninstaller would have to clear
`~/Library/Containers/org.misstype.inputmethod.Misstype`.

## What the installer does

1. Copies the bundled `MisstypeIME.app` next to the target, stops a running
   copy (terminate, then force), swaps it in atomically.
2. `lsregister -f`, restarts `TextInputMenuAgent`/`TextInputSwitcher`.
3. `TISRegisterInputSource`; on a **first install** also enables the sources.
   Updates never re-enable a source the user removed.
4. If TIS does not list the source yet (the normal case for a brand-new input
   method), it says so and offers **Log Out…** — macOS only shows a new input
   method after the next login. Otherwise it offers to open Keyboard
   settings. It never launches the IME by hand (see `install_ime.sh`).

`Install Misstype.app --yes` skips the dialogs and prints the outcome.
It warns when an older `/Library/Input Methods/MisstypeIME.app` exists.

## Rename: Mistype → Misstype (decision 2026-10-04)

The product is Misstype (隨打注音). Until now only display text said so while
every identifier said `Mistype`; the two are unified, including the bundle id
(`org.misstype.inputmethod.Misstype`, connection name `…Misstype_Connection`),
Swift modules, C ABI (`misstype_*`, `misstype.h`), the Python package and the
Linux addon. Consequences: an install of v0.0.1 (old bundle id) is a different
app to macOS and Sparkle, so it cannot update itself in place — reinstall from
the new DMG; its sandbox container, preferences and `user_dictionary.tsv` stay
under the old id and are not migrated (copy the dictionary over by hand).
Linux data moves from `~/.local/share/mistype` to `~/.local/share/misstype`.

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

Commit and push changes first. The normal path is **Actions → Tag release →
Run workflow**, selecting `major`, `minor`, or `patch` (default `patch`).
It creates an annotated tag at the current remote `main` HEAD, then invokes
the release build for that exact tag. The version is calculated from the
numerically highest stable `vMAJOR.MINOR.PATCH` tag; prerelease and unrelated
tags are ignored. A major/minor bump resets the lower components. Dispatches
are serialized, and existing tags are never overwritten.

```sh
gh workflow run tag-release.yml --ref main -f bump=minor
# Or choose an explicit version and tag the intended local HEAD:
git tag -a v0.3.0 -m 'Misstype 0.3.0'
git push origin v0.3.0                       # CI: test, package, publish
./script/package_release.sh 0.3.0            # local packaging into dist/
```

`Tag release` uses the built-in `GITHUB_TOKEN`. GitHub suppresses tag-push
workflow triggers for that token, so it explicitly dispatches `release.yml`
at the new tag with `publish=true`. No additional PAT is necessary. Builds
stay in the original Release workflow to preserve its increasing run number
for Sparkle's `CFBundleVersion`.
Direct user tag pushes still trigger Release normally. Direct manual
dispatch of Release builds artifacts without publishing by default; its
optional `publish` checkbox requires dispatching at the existing version tag
(`--ref <tag>`) with `version=<tag>`. Publishing from a branch while specifying
a different tag is rejected. Every build checks out `github.sha`, and verifies
that HEAD matches the source commit recorded in its attestation certificate.
Publishing requires an existing remote tag (`gh release create --verify-tag`).
If tagging succeeds but the release build fails, rerun the failed jobs in
the Release run. If its dispatch fails, use the existing tag with
`gh workflow run release.yml --ref <tag> -f version=<tag> -f publish=true`.
Starting a new Tag release dispatch calculates another version.

Release immutability is enabled for future releases. CI creates a draft,
uploads **all** assets (including the provenance bundle), then publishes the
draft. Publication locks the assets and tag. If an upload fails leaving a
draft, remove only that unpublished draft before rerunning the failed job;
never replace published assets or move their tag. A correction to a published
release needs a new version.

Hypothesis (2026-10-07): creating a tag with the built-in token alone will
leave a release unbuilt. The smallest check is that the tag job dispatches
Release at its new version tag, which checks out that tag and publishes.
Version calculation is covered by `tests/test_release.py`; workflow syntax
and the dispatch inputs should be validated before pushing. End-to-end
publication is checked on the next explicitly requested release, since
running Tag release creates and publishes a new version.

Verified 2026-10-07: actionlint 1.7.12 validated all repository workflows,
and all 73 Python tests passed, including the five version-calculation tests.
The preceding direct tag-push release `v0.2.0` completed successfully. The new
Tag release dispatch has not been run to avoid creating an additional release.

Artifacts: `Misstype-<v>.dmg`, `MisstypeIME-<v>.zip` (the Sparkle archive),
`appcast.xml`, `.sha256` files, and (when public)
`build-provenance.sigstore.json`.
Tags containing `-` are prereleases and are
skipped by `latest`, so they never reach existing installs.

## Verify build provenance

目前 repository 保留 private。GitHub 原生 attestation 不支援個人帳號的
private repo，因此 private 期間略過此步驟，CI 摘要會明確註記未產生證明；
repository 公開後的新建置會自動啟用。既有成品不會因此補上證明，v0.2.0
也未附上此證明。限制見 [GitHub 支援範圍](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)。

Release workflow 在簽章、公證、stapling 與 checksum
完成後，使用固定 commit 的 `actions/attest`，對最終 DMG、更新 ZIP、checksum
和有提供時的 appcast 產生 GitHub/Sigstore 證明。Artifact-only dispatch 也會
產生證明，方便驗證流程而不建立公開 release。公開後證明失敗就不會發布，
不會默默退回沒有證明的版本。

下載後可用新版 [GitHub CLI](https://cli.github.com/) 核對成品雜湊、repository、
release workflow、來源 tag，以及是否由 GitHub-hosted runner 建置。
以下 `v0.2.1` 是範例，請改成實際附有證明的版本：

```sh
RELEASE_TAG=v0.2.1
gh release download "$RELEASE_TAG" --repo Yukaii/misstype \
  --pattern 'Misstype-*.dmg' --pattern 'build-provenance.sigstore.json'
gh attestation verify "Misstype-${RELEASE_TAG#v}.dmg" \
  --repo Yukaii/misstype \
  --signer-workflow Yukaii/misstype/.github/workflows/release.yml \
  --source-ref "refs/tags/$RELEASE_TAG" \
  --deny-self-hosted-runners
```

若已核對原始碼 commit，可再加上 `--source-digest <完整 commit SHA>`。
同一個指令也適用於更新 ZIP、checksum 和 appcast，替換檔名即可。
若要使用 release 附的證明檔而非向 API 取得證明，加上
`--bundle build-provenance.sigstore.json`。
詳見 [GitHub CLI 驗證參數](https://cli.github.com/manual/gh_attestation_verify)。

Immutable release 本身另有 GitHub 的 release attestation，可驗證下載檔
仍是該版本正式發布時的附件：

```sh
gh release verify-asset "$RELEASE_TAG" "Misstype-${RELEASE_TAG#v}.dmg" \
  --repo Yukaii/misstype
```

建置證明記錄成品來源，不保證程式行為安全，也不代表已通過獨立重建。
Sparkle 自動更新仍使用既有的 EdDSA 驗證，不會自動執行上述 provenance
檢查。[GitHub attestation 說明](https://docs.github.com/en/actions/concepts/security/artifact-attestations)
與 [immutable release 說明](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)。

Hypothesis (2026-10-07): the final downloaded files can be bound to the
workflow's actual source commit without publishing a new version. The smallest
experiment is an artifact-only Release dispatch at the implementation commit,
then download its artifacts and verify their attestations with the expected
workflow and source SHA. A modified copy must fail verification. Source/ref
guards and draft-before-publication are also checked before pushing.

Verified locally 2026-10-07: actionlint 1.7.12 validated all workflows;
241 Swift tests (8 skipped) and 73 Python tests passed. Manual execution of
the workflow's shell steps passed five source/ref cases (including mismatched
SHA, branch publication, and a different tag) and eight mocked publication
cases (stable/prerelease, optional provenance bundle/appcast, and upload failure preventing
publication). An actual immutable publication is checked on the next
requested release.

CI check 2026-10-07: [run 37619947915](https://github.com/Yukaii/misstype/actions/runs/37619947915)
passed tests, signing, and notarization, but GitHub rejected native attestation
storage because the repository is user-owned and private. Nothing was published.
The maintainer chose to keep it private and enable attestation after publication;
the workflow now gates attestation and its bundle on public visibility. Signed
bundle verification and the tampered-file rejection experiment remain pending
until a new run after the repository becomes public (do not rerun an old private
event, whose visibility payload is unchanged).

Verified private mode 2026-10-07: [run 37620748448](https://github.com/Yukaii/misstype/actions/runs/37620748448)
at `705c09756fc2c831143bf5e368fa4bab117522d6` passed tests, signed/notarized
packaging, the deferred-attestation notice, and artifact upload. Attestation,
bundle generation, and release publication were skipped as intended. The five
downloaded files included no provenance bundle; the DMG and update ZIP matched
their SHA256 files. No release or tag was created, and the repository remained
private.

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
  started its updater (`.MisstypeIME.installing` path); restarting it fixed
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

- Uninstaller (remove the bundle, `MisstypeSourceTool disable`, optionally the
  user data under the container).
- Delta updates, release channels, downgrade protection beyond Sparkle's
  build-number comparison.
- Linux packaging (see `docs/linux-port.md` L4).
