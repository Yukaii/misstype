# Arch Linux / Omarchy installation

Misstype is an fcitx5 addon. The recipe in `linux/aur/PKGBUILD` builds
`fcitx5-misstype-git` from upstream Git and packages every system file for
pacman-managed installation/removal. It is published on
[AUR](https://aur.archlinux.org/packages/fcitx5-misstype-git):

```sh
yay -S fcitx5-misstype-git
```

This VCS package builds the latest upstream Git source, not a fixed release.
After installation, follow [Install and enable](#install-and-enable).

Hypothesis: the existing Linux addon can run against Arch's fcitx5 without
adapter changes. The smallest falsification is `makepkg` (Zig tests, C ABI
smoke test, fcitx5 headless conformance), followed by the real-lexicon smoke
check and desktop checks below. Decode is offline; packaging changes no
candidate scoring or per-keystroke latency.

## IBus instead of fcitx5

`linux/aur-ibus/PKGBUILD` builds `ibus-misstype-git`, the IBus engine
(`docs/ibus-port.md`) with its settings window. It is built from the same
sources and data as the fcitx5 package, so the two **conflict** (both ship
`libMisstypeCAPI.so`, the lexicon and `misstypectl`); install one. It is not
published on the AUR yet. Build it from a checkout like the fcitx5 one:

```sh
export MISSTYPE_SOURCE_URL="file://$(git rev-parse --show-toplevel)"
cd linux/aur-ibus && makepkg -s
sudo pacman -U ./ibus-misstype-git-*.pkg.tar.zst
ibus restart    # then add Misstype under Input Sources / ibus-setup
```

On Omarchy, fcitx5 owns the input method (`omarchy-fcitx5.service`,
`XMODIFIERS=@im=fcitx`); switch it off before using IBus, see
[`ibus-port.md`](ibus-port.md#install-from-source). `check()` runs the Zig
suite and the C ABI smoke test; the headless IBus suite runs in CI
(`script/linux/test_ibus.sh`). A clean rootless Arch `x86_64` container build
passed on 2026-10-11, including `check()` (Zig ReleaseFast tests and C ABI
smoke test). See the verification record below; desktop acceptance is still
open.

## Prebuilt release packages (`-bin`)

The recipes in `linux/aur-fcitx5-bin` and `linux/aur-ibus-bin` repackage
checksum-pinned GitHub Release assets without compiling Zig or the adapter.
They support **x86_64 only**; the `-git` recipes remain the source-build option.
Choose one frontend: all variants conflict because they share the core, data
and CLI. After the maintainer's initial AUR publication, install with:

```sh
yay -S fcitx5-misstype-bin     # Arch / Omarchy, fcitx5
yay -S ibus-misstype-bin       # IBus desktop; choose this instead
```

Until those names are published, use `makepkg -si` in the corresponding recipe
directory, or download the native Arch asset from the latest Release and use
`pacman -U`. Restart your input framework and follow the activation and desktop
spot checks below. Remove with `pacman -Rns fcitx5-misstype-bin` (or
`ibus-misstype-bin`); personal learning data stays in your home directory.

Hypothesis: repackaging the tested release payload gives the same offline IME
without a user-side compiler/toolchain download. The smallest falsification is
`script/linux/test_aur_bin.sh` in a disposable current Arch container: makepkg,
payload-path comparison, pacman install/remove, every ELF's `ldd`, the installed
C ABI/session smoke fixture, CLI tests and frontend headless conformance. CI
compiles only the test drivers, never the installed core or adapter. Only the license-directory package
name changes; the executables, data and addon are unchanged. Decoding quality
and per-key latency are therefore unchanged by packaging.

### Binary publication and rolling-Arch compatibility

Release calls `.github/workflows/aur-bin.yml` **after** publishing a stable
release. Preparation downloads each asset and `.sha256`, verifies the checksum
and (for a public upstream) GitHub provenance from `release.yml` at that tag,
updates `pkgver`/checksum, and generates `.SRCINFO` with makepkg. The preview
artifact contains the exact AUR files. PKGBUILD execution and installation run
in a container without AUR credentials; only the publisher receives the SSH key.
The committed recipes are a reproducible v0.4.2 baseline; later versions and
checksums are generated in the preview/AUR repository, without committing
version-only updates upstream.

The AUR account/key must own or be able to create **each** binary package base.
Reuse `AUR_MAINTAINER` and `AUR_SSH_PRIVATE_KEY` from the VCS setup. First
publication requires an explicit manual dispatch at a published stable tag
containing this workflow, with the matching `tag` input:

```sh
# Replace vX.Y.Z with a published stable tag containing aur-bin.yml.
gh workflow run aur-bin.yml --repo Yukaii/misstype --ref vX.Y.Z \
  -f tag=vX.Y.Z -f publish=true -f publish_fcitx5_bin=true -f publish_ibus_bin=true
```

After confirming each package on AUR, set repository Actions variables
`AUR_FCITX5_BIN_PUBLISHED=true` and `AUR_IBUS_BIN_PUBLISHED=true` separately.
Future stable releases then synchronize them automatically. Branch pushes,
PRs and ordinary manual dispatches only verify/upload previews. Retry with the
same command and `publish=true`, omitting first-publication flags after setup.
Artifact-only releases and prereleases cannot publish binary AUR packages.
The publisher refuses to downgrade an existing AUR version or `pkgrel`, so an
older release retry cannot overwrite a newer release or maintainer rebuild.

A daily scheduled run downloads the latest stable release and installs it on
fully updated Arch, checking library resolution, installed-core fixtures and
headless conformance against the installed frontend.
Failures appear in Actions and its normal workflow notifications; they never
publish packages. Maintainers should triage an ABI failure within one day and
cut a new patch release against current Arch before recommending `-bin` again.
Published assets are immutable: never replace them or move the tag. Users can
use `-git` to rebuild against current libraries while awaiting that release.
This monitor does not replace Omarchy/GNOME desktop acceptance.

### Binary verification record (2026-10-11)

Both v0.4.2 Arch release assets passed SHA-256 and GitHub attestation verification
(upstream `release.yml`, source ref `refs/tags/v0.4.2`). In separate fresh rootless
Podman containers based on `archlinux:base-devel`, updated with `pacman -Syu`:

- `makepkg --cleanbuild --force` repackaged each asset as `0.4.2-1` with no Zig
  download or core/adapter compilation. Generated `.SRCINFO` matches both
  committed recipes.
- `pacman -Qkk`: fcitx5 88 files, IBus 84 files, **0 altered files**. Payload
  lists match the source-built release packages after renaming the license
  directory. Install and `pacman -Rns` removal passed for both.
- `ldd` resolves all shipped ELF binaries/libraries. The fcitx5 addon links
  `libFcitx5{Core,Config,Utils}`, the private core, C++/GCC and libc runtimes;
  IBus links `libibus`, GLib/GObject/GIO and the same core/runtimes. GTK tools
  link GTK4/GLib (optional for fcitx5, required for IBus). The core and CLI
  require libc, not Swift or libcurl. Transitive libraries' Arch owners are
  recorded in the test log.
- Installed C ABI smoke fixture passed; each installed CLI passed 11 tests.
  Test-only drivers against installed release addons passed: fcitx5 reports
  all 19 scenarios; IBus reports C1–C15 and LR1–LR5, `IBUS OK`.
- Python suite: 85 tests, one macOS-only skip. Focused pinning/publisher tests,
  shellcheck on the packaging scripts and actionlint on `aur-bin.yml` passed.
  Release workflow structure validates with actionlint's shellcheck disabled;
  its pre-existing macOS keychain script has an unrelated SC2046 warning.

To replay after downloading the two Arch assets and `.sha256` files:

```sh
python3 script/linux/prepare_aur_bin.py linux/aur-fcitx5-bin /path/to/assets v0.4.2 /path/to/prepared-fcitx5
python3 script/linux/prepare_aur_bin.py linux/aur-ibus-bin /path/to/assets v0.4.2 /path/to/prepared-ibus
# Repeat with prepared-ibus for the other frontend. No host sudo is needed.
podman run --rm --user root -v "$PWD:/src:ro" \
  -v /path/to/prepared-fcitx5:/package -v /path/to/assets:/assets:ro \
  docker.io/library/archlinux:base-devel \
  bash /src/script/linux/test_aur_bin.sh /package /assets /src
```

The first upstream workflow/AUR push and Omarchy/GNOME desktop activation,
candidate placement and typing spot checks remain maintainer/manual acceptance.

## Quick install from a checkout

For testing a branch on your own desktop, from the repository root:

```sh
script/linux/install_ime.sh            # add --check to run the test suites too
```

It builds a package from the checked-out commit with the recipe below
(uncommitted edits are not included), installs it with `sudo pacman -U`,
restarts fcitx5 (through its systemd user unit when one runs it, such as
Omarchy's `omarchy-fcitx5.service`; otherwise with its current flags), warns if
more than one fcitx5 is left running, and adds Misstype to the current
input-method group if it is missing. The build directory
`.cache/aur-build` is kept, so later runs rebuild incrementally. On other
distributions the same script runs `script/linux/build.sh` and
`sudo cmake --install build/fcitx5`.

## Build a package

IBus packaging verification for issue #63 (2026-10-11), in a fresh Arch
container with the recipe's build dependencies installed:

```sh
script/linux/package_arch.sh 0.0.0 ibus
```

- Clean `makepkg --cleanbuild --force` completed against local committed
  source `e00e96c`, producing `ibus-misstype-git-0.1.r263.ge00e96c-1-x86_64`
  (release asset `MisstypeIBus-0.0.0-arch-x86_64.pkg.tar.zst`; `0.0.0` is a
  local verification version, not a published release).
- All pinned dictionary and Zig download checksums passed. Zig ReleaseFast
  tests and the C ABI smoke check passed (35 exports, `CAPI OK`).
- The package staged the engine, GTK4 Preferences tool, component XML,
  private core library, lexicon, `misstypectl`, licences and icons.
- Both recipes' committed `.SRCINFO` files match `makepkg --printsrcinfo`
  with the source override unset. Publisher tests cover both destinations,
  file lists, unchanged-publication no-op and authorization failures.
- This run built the package; pacman install/remove and GNOME desktop
  acceptance were not exercised by this command.

Install `base-devel`, `cmake`, `ninja`, and `git`. The recipe downloads its
checksum-pinned Zig toolchain as a makepkg source. On Omarchy:

```sh
omarchy pkg add base-devel cmake ninja git
```

From the repository root:

```sh
cd linux/aur
makepkg -s
```

To build from your local committed checkout instead of GitHub:

```sh
# Run from the repository root.
export MISSTYPE_SOURCE_URL="file://$(git rev-parse --show-toplevel)"
cd linux/aur
makepkg -s
```

Use a fresh build directory when changing the source URL (makepkg caches a
bare Git clone named `misstype`). The override is only for local builds;
generate publication metadata with `MISSTYPE_SOURCE_URL` unset.

Run makepkg as your normal user. It downloads upstream source plus pinned,
SHA-256-verified public dictionary data before building. The build/check
phases then use local data. `check()` runs the Zig suite, C ABI smoke test,
and headless fcitx5 conformance tests. Swift is no longer a build or runtime
dependency. The library statically embeds the vendored utf8proc implementation. `x86_64` and `aarch64` are
declared; see the verification record for architectures actually tested.

The addon uses C++20 for current fcitx5 headers (`std::source_location`).
The recipe carries the matching CMake patch until it is merged upstream.
Zig manages its optimization and debug information; the recipe keeps LTO
and split debug packaging disabled.

The recipe follows upstream Git, so it builds committed upstream code,
not uncommitted edits in your working tree. When dictionary manifests change
upstream, update the recipe's pinned URLs and hashes together. Missing or
changed manifest data fails checksum verification.

## Install and enable

```sh
sudo pacman -U ./fcitx5-misstype-git-*.pkg.tar.zst
```

Install application integrations if they are missing:

```sh
omarchy pkg add fcitx5-configtool fcitx5-gtk fcitx5-qt
```

1. Finish any active composition, then log out/in so fcitx5 discovers the
   addon. If fcitx5 already runs, its tray menu's **Restart** also works.
2. Open `fcitx5-configtool`, choose **Add Input Method**, disable **Only Show
    Current Language** if necessary, search for **Misstype**, and add it.
3. Use fcitx5's configured activation shortcut (commonly Ctrl+Space).
   A lone Left Shift uses fcitx5's English/Chinese toggle.
4. Type `su3cl3` on the standard physical Zhuyin layout: expect **你好** in
   preedit, then Return to commit. Space is first tone, not commit.

On Omarchy, first check the existing fcitx5 setup before changing Hyprland:

```sh
pgrep -a fcitx5
printenv QT_IM_MODULE XMODIFIERS
```

A running fcitx5 plus `QT_IM_MODULE=fcitx` and `XMODIFIERS=@im=fcitx` is the
usual starting point. Native Wayland support is application-specific; test
Firefox, a GTK editor, your terminal, and Chromium/Electron separately.
Chromium/Electron may need `--enable-wayland-ime`. An app-specific failure
should be recorded in the [Linux desktop acceptance checklist](linux-port.md#l6-desktop-acceptance-human-or-vm).

Check candidate arrows/Tab/click, Backspace repeat, English toggle, cursor
movement, and focus change mid-composition. Headless tests cannot validate
the candidate window placement or client-side caret styling.

## Candidate window and vertical rows

Linux uses the candidate window supplied by fcitx5. Misstype gives fcitx5 one
list of candidates; the desktop panel decides its orientation, where it appears,
and whether it has a border, shadow, or theme. This is different from the
macOS Misstype panel, so a vertical list beside the caret is expected.

While the list is visible:

- `Up` and `Down` move the highlighted row.
- `Tab` and `Shift+Tab` page through the list.
- The home-row selection keys (by default `a s d f g h j k`) choose the visible
  rows once selection keys are active; before that, these keys type Zhuyin.
- Clicking a row selects it when the application supports fcitx5 candidate
  clicks. `Return` confirms according to the current fcitx5/Misstype settings;
  a second `Return` commits the completed composition.
- `Escape` leaves candidate selection and keeps the current preedit.

If candidates do not appear, confirm that **Misstype** is the active input
method rather than `keyboard-us`, restart fcitx5, and check that the desktop
environment is loading the fcitx5 frontend (`QT_IM_MODULE=fcitx` and
`XMODIFIERS=@im=fcitx`). A panel that appears in the wrong place or uses a
horizontal layout is controlled by the desktop's fcitx5 UI; it does not change
decoding or candidate order.

## Remove cleanly

First remove Misstype from the list in `fcitx5-configtool`, switch to another
input method, then:

```sh
sudo pacman -R fcitx5-misstype-git
```

Restart fcitx5 or log out/in afterwards. Pacman removes the addon, private
core library, dictionaries, configuration descriptors, and licenses. It
preserves fcitx5 and your other input methods. Local learning and your user
dictionary remain in `${XDG_DATA_HOME:-$HOME/.local/share}/misstype/`; remove
that directory yourself only if you also want to erase your personal data.

Build-only tools can be removed separately if you no longer need them:

```sh
sudo pacman -Rns swift-bin
```

## AUR publication

An AUR maintainer must register `fcitx5-misstype-git`, add their
maintainer contact to `PKGBUILD`, and push `PKGBUILD` plus `.SRCINFO` to its
separate AUR Git repository. Generate metadata after recipe/version changes:

```sh
makepkg --printsrcinfo > .SRCINFO
```

Users can install with
`omarchy pkg aur add fcitx5-misstype-git` (or `yay -S fcitx5-misstype-git`).

### Automated synchronization and branch preview

`.github/workflows/aur.yml` validates packaging on relevant branch pushes
and PRs and uploads separate `aur-package-fcitx5-misstype-git` and
`aur-package-ibus-misstype-git` previews containing only `PKGBUILD`,
`.SRCINFO`, and the packaging license (`LICENSE`, MIT), plus `cxx20.patch`
for fcitx5.
It regenerates `.SRCINFO` in a credential-free Arch container and requires
it to match the committed metadata. This is a metadata check, not a full
package build; run `makepkg` with its `check()` suite before publication.
Hypothesis: these package-specific files are enough to synchronize the AUR recipe
without exposing credentials to PKGBUILD execution. The smallest check is
a branch preview, inspection of its artifact, then an initial publish and
an unchanged repeat run (which should make no AUR commit).

One-time setup by the AUR maintainer and GitHub administrator:

1. Generate a dedicated Ed25519 SSH key, separate from personal keys:
   `ssh-keygen -t ed25519 -f ~/.ssh/aur-misstype-ci -C 'misstype AUR automation'`.
   Use an empty passphrase for unattended CI. Append its public key to the
   AUR account's SSH keys, one key per line. The private key must stay private.
2. In GitHub **Settings → Secrets and variables → Actions → Repository secrets**,
   set `AUR_MAINTAINER` to the public contact, e.g.
   `Your Name <you at example dot org>`. This contact is included in the
   published PKGBUILD and preview artifact; it is not private package metadata.
3. Add repository secret `AUR_SSH_PRIVATE_KEY` containing the entire private
   key, including its BEGIN/END lines. No GitHub environment is required.
   The workflow restricts publishing to upstream `main` and published stable
   version tags, and passes the private
   key only to the publishing step. Protect `main` with review requirements
   to control changes to the workflow and publisher.
4. Ensure the account owns or co-maintains `fcitx5-misstype-git`, or that the
   name is available for the initial push. Initial publication can be done
   manually as above or by the workflow's first authorized push.
5. For IBus, confirm that `ibus-misstype-git` is available or that the account
   owns/co-maintains it. The existing AUR key can create a second package:
   keys authorize the account, not a particular package. The first IBus push
   requires an explicit manual dispatch with both `publish=true` and
   `publish_ibus=true`. After reviewing the resulting AUR package, set the
   repository **Actions variable** `AUR_IBUS_PUBLISHED=true` to enable IBus
   synchronization on main pushes and published stable releases. Leave it
   unset until that initial publication is confirmed.

AUR SSH keys are account-wide, not restricted to a single package. Giving
upstream CI this key trusts its repository administrators with the AUR
account's package-write permissions. Revoke only the CI key by removing its
public key from the AUR profile and deleting the GitHub secret.

Test a branch by pushing a packaging/workflow change; branches and PRs
only prepare the preview and skip publishing. There are no branch-publishing
exceptions or commit-message overrides. Forks cannot publish.
For a new workflow, GitHub enables manual dispatch after the workflow exists
on the default branch. After merging, a relevant push to `main` automatically
publishes. To retry or preview manually:

```sh
gh workflow run aur.yml --ref main                    # preview only
gh workflow run aur.yml --ref main -f publish=true    # publish
# First IBus publication (also synchronizes fcitx5):
gh workflow run aur.yml --ref main -f publish=true -f publish_ibus=true
# Retry the packaging from an already published stable version tag:
gh workflow run aur.yml --ref v0.3.0 -f publish=true
```

Publishing uses strict SSH host checking against AUR's published Ed25519
fingerprint, an explicit file list, and normal non-force pushes. It skips
unchanged packaging and does not bump `pkgver` for upstream commits/releases:
this is a VCS package. Update pinned source URLs/hashes when manifests change.
Release calls this reusable workflow after successfully publishing a stable
GitHub Release, using the exact release commit. Both direct tag pushes and
the Tag release workflow's explicit Release dispatch use this path; no
`release: published` event is needed (events created by `GITHUB_TOKEN` would
not trigger another workflow). Artifact-only runs, prereleases, and failed
releases do not publish to AUR. Relevant `main` pushes still synchronize
packaging fixes between releases. AUR failures do not undo an already
published GitHub Release; fix the cause and retry the AUR workflow.
IBus automatic synchronization additionally requires `AUR_IBUS_PUBLISHED=true`;
neither merging the workflow nor a Release dispatch creates it before the
maintainer explicitly authorizes its first push.

## AUR verification (2026-10-10)

- Initial publication from PR #55's temporary branch test succeeded; AUR lists
  `fcitx5-misstype-git` with maintainer `pastleo`. The temporary branch
  publication exception was removed after testing.
- `yay --aur -S --noconfirm fcitx5-misstype-git` downloaded public sources,
  verified every non-VCS SHA-256 checksum, and built upstream `bf0c118` as
  `fcitx5-misstype-git-0.1.r250.gbf0c118-1-x86_64.pkg.tar.zst`.
- Zig ReleaseFast checks completed successfully; the C ABI smoke check reported
  35 exports matching the header and `CAPI OK`; fcitx5's headless test passed.
- The agent's installation step stopped at the interactive sudo password;
  the contributor subsequently confirmed `yay -S` installation succeeded.
- The stable-release reusable-workflow integration still needs its first
  post-merge Release run. The unchanged-publication no-op has not been
  independently confirmed here.

## Verification record (2026-10-05)

This record predates upstream's Mistype → Misstype rename. The current
recipe uses the new package, library, addon and data-directory names;
the artifact names below describe the earlier build.

Native Omarchy / Arch `x86_64`, fcitx5 5.1.22, Swift 6.4.0 (`swift-bin`):

- Local Git source `a009912` plus the C++20 build patch:
  `MISTYPE_SOURCE_URL=file:///path/to/mistype makepkg -L` completed.
- Swift: 176 tests, 3 optional measurement tests skipped, 0 failures.
- C ABI: 19 exported symbols match the header; `CAPI OK`.
- fcitx5: C1–C13 and LR1–LR4, all 17 scenarios passed.
- Packaged/stripped addon loads; its private core library has no dynamic
  Swift runtime dependency. Addon RUNPATH is `/usr/lib/mistype`.
- Real packaged dictionary: `su3cl3` → `commit=你好` via the C smoke tool.
- Final package: `fcitx5-mistype-git-0.1.r125.ga009912-1-x86_64.pkg.tar.zst`,
  approximately 22 MiB compressed / 61 MiB installed. `.SRCINFO` matches
  `makepkg --printsrcinfo` with the public source URL.

This verification built a package only. Desktop app acceptance and actual
pacman installation/removal remain manual checks; `aarch64` packaging has
not yet been tested on Arch.

## Upstream rebase verification (2026-10-06)

Updated the recipe for upstream `f81597d` (155 commits) and the
Mistype → Misstype rename, including `MisstypeCAPI`, `MISSTYPE_CAPI_DIR`,
the source URL and `fcitx5-misstype-git` package name. The package conflicts
with the previous `fcitx5-mistype-git` name to prevent parallel installs.

- `bash -n PKGBUILD` passes; `.SRCINFO` matches `makepkg --printsrcinfo`.
- Native `bash script/linux/test_all.sh` passes: 199 Swift tests (4 optional
  measurements skipped), 19 C ABI exports, and all 17 fcitx5 scenarios.
- Python prototype: 68 tests, 1 macOS-only check skipped, 0 failures.

Full native package build and installation also passed:

- `MISSTYPE_SOURCE_URL=file:///path/to/mistype makepkg -L` completed,
  including the Swift, C ABI and fcitx5 checks.
- Artifact: `fcitx5-misstype-git-0.1.r155.gf81597d-1-x86_64.pkg.tar.zst`,
  22.45 MiB compressed / 62.24 MiB installed.
- `pacman -U` replaced the old `fcitx5-mistype-git` package;
  `pacman -Qkk fcitx5-misstype-git` reports 51 files, 0 altered.
- Installed addon dependencies resolve, including the private library at
  `/usr/lib/misstype/libMisstypeCAPI.so`; no dynamic Swift runtime is needed.
- A C smoke binary linked against the installed library and dictionaries
  returns `commit=你好` for `su3cl3`.
- Existing fcitx5 profile entries were updated from `mistype` to `misstype`;
  the restarted fcitx5 recognizes the renamed input method.

Desktop typing acceptance and removal remain manual checks. The earlier
package-size measurements above remain historical.

## Upstream rebase verification (2026-10-07)

Upstream rewrote its history: the old `f81597d` tree matches rewritten
`6967ba0` exactly. Local AUR changes were reapplied onto `5135a1f` (212
commits), preserving the C++20 patch. Package metadata now also lists
CC-BY-SA-4.0 for the bundled English word list.

- Clean native `MISSTYPE_SOURCE_URL=file:///path/to/mistype makepkg -CL`
  completed: 246 Swift tests (8 optional measurements skipped), 24 C ABI
  exports matching the header, and the fcitx5 conformance suite passed.
- Python: 73 tests, 1 macOS-only check skipped, 0 failures.
- Artifact: `fcitx5-misstype-git-0.1.r212.g5135a1f-1-x86_64.pkg.tar.zst`,
  22.53 MiB compressed / 62.50 MiB installed.
- Pacman upgrade completed; package integrity reports 63 files, 0 altered.
- Restarted fcitx5 recognizes `misstype`; the installed C library and
  dictionaries return `commit=你好` for `su3cl3`.
