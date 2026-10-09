# Arch Linux / Omarchy installation

Misstype is an fcitx5 addon. The recipe in `linux/aur/PKGBUILD` builds
`fcitx5-misstype-git` from upstream Git and packages every system file for
pacman-managed installation/removal. It is an **AUR submission candidate**;
it has not been published to the AUR.

Hypothesis: the existing Linux addon can run against Arch's fcitx5 without
adapter changes. The smallest falsification is `makepkg` (Zig tests, C ABI
smoke test, fcitx5 headless conformance), followed by the real-lexicon smoke
check and desktop checks below. Decode is offline; packaging changes no
candidate scoring or per-keystroke latency.

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

After publication, users can install with
`omarchy pkg aur add fcitx5-misstype-git` (or `yay -S fcitx5-misstype-git`).

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
