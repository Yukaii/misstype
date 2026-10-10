# IBus port: sketch

Status (2026-10-10): **adapter and headless suite landed** (`linux/ibus/`,
`script/linux/test_ibus.sh`): C1–C15 plus delivery rules LR1–LR5 pass against a
real ibus-daemon (Ubuntu 24.04, ibus 1.5.29) with the engine process, in the
Linux dev image and CI (inside `script/linux/test_all.sh`). **Not verified:**
a real desktop (GNOME Shell's candidate popup, Wayland sessions, GTK/Qt
clients, browsers) and distro packaging; those are I5 and I6 below.

**Goal:** Misstype runs as an IBus engine (GNOME's default on Ubuntu, Fedora
and Debian) with the same behavior as macOS and fcitx5, over the same C ABI,
verified against the conformance scenarios C1–C15 in `docs/cross-platform.md`.

**Non-goals:** a second settings model (reuse `conf/misstype.conf` and
`misstypectl`, see `docs/linux-port.md` L7), a custom candidate window, new
decoding behavior. Anything that changes what a key sequence produces belongs
in the Zig `Session`, not here.

## Why it is cheap

The adapter is only I/O. fcitx5's is ~470 lines (`linux/fcitx5/src/engine.cpp`)
on top of `misstype.h`, the evdev key table and the headless suite. IBus needs
the same three jobs: translate key events, apply `misstype_key_result`, draw
`misstype_view`.

## Mapping onto the contract

| Contract (`cross-platform.md`) | IBus |
| --- | --- |
| Key translation §1 | `IBusEngine::process_key_event(keyval, keycode, state)`. `keycode` is expected to be an evdev code, so `misstype_key_from_evdev` applies as on fcitx5 (**spike**: confirm, including under Wayland). `text` from `ibus_keyval_to_unicode(keyval)`. Releases carry `IBUS_RELEASE_MASK` in `state`. |
| Modifiers after the event | `state` is the state **before** the event (as X11/fcitx5): correct the Shift keys the same way. |
| Commit | `ibus_engine_commit_text`. |
| Preedit §3 | `ibus_engine_update_preedit_text` with the caret in **characters** (not bytes); use `caret_utf16` only if the text is BMP, else convert (**spike**). Segments and mark ranges become `IBusAttrUnderline` / background attributes. |
| Candidates §3 | `IBusLookupTable`: page size from `view.page_size`, cursor = `selected`, labels = `selection_keys`. The shell or panel draws the list, so row styling is not ours (known limit). |
| Row click | `IBusEngine::candidate_clicked` → `misstype_session_pick`. |
| Page keys | translate to `MISSTYPE_KEY_PAGE_UP/DOWN`; redraw the page holding `selected`. Never call `ibus_lookup_table_page_up` ourselves (the session owns the highlight). |
| Lifecycle §4 | `focus_in` → `reset_modifiers`; `focus_out` / `reset` / `disable` → `commit()`, insert if non-nil (no client-side preedit rule to special-case unless the **spike** finds one). One engine per process, one session per `IBusEngine` instance. |
| Delivery rules | return `TRUE` iff `consumed`; never swallow releases or bare modifiers (same reasoning as fcitx5). |
| Threading §5 | everything on the GLib main loop thread. |
| Data §6 | same files as fcitx5: `$XDG_DATA_HOME/misstype/*`, `/usr/share/misstype` lexicon. Settings read from `conf/misstype.conf` at engine start and on `misstypectl config` (no IBus-native settings page). |

## Tasks

Mirror the numbering of `docs/linux-port.md`; each task ends with a command
that passes.

- **I0 Spike (half a day).** *Mostly answered by the headless suite; the
  desktop items stay open.* Verified: the engine receives the evdev code the
  client sent (upstream ibus clients send `hardware_keycode - 8`), releases
  arrive with `IBUS_RELEASE_MASK`, preedit carets are in characters, and the
  daemon commits a `PREEDIT_COMMIT` preedit on focus out for clients with and
  without preedit support. Still open: how GNOME draws the lookup table, and
  Wayland compositors that send keysyms without scancodes (the engine falls
  back to the keysym). On Ubuntu 24.04 GNOME (Wayland) and an X11
  session, log `process_key_event` arguments for a few keys. Answer: keycode
  numbering, release delivery, whether Shift/modifier-only events arrive, how
  preedit carets are measured, whether `focus_out` also commits client-side
  preedit, how GNOME draws the lookup table. Write the results into this file.
- **I1 Engine skeleton (done).** `linux/ibus/` (C++ or C with GLib, decide by the
  spike: `libibus` has no maintained C++ binding). Component XML under
  `/usr/share/ibus/component/misstype.xml`, an `--ibus` launch mode for the
  engine binary, build in the existing Docker image (`script/linux/dev.sh`).
- **I2 Conformance harness (done).** C1–C15 headless. IBus has no `testfrontend` like
  fcitx5, so drive the engine class directly with a fake `IBusEngine` sink
  that records commit / preedit / lookup-table calls, plus one smoke test
  through a real `ibus-daemon` in the container if it runs headless.
- **I3 Settings and data (done, shared file).** Reuse `MisstypeConfig` keys through
  `misstypectl config` (keep the key list in `core-zig/src/ctl.zig` in step);
  nothing new in the ABI.
- **I4 CI (done).** Add the IBus suite to `script/linux/test_all.sh` and the existing
  Linux matrix in `.github/workflows/ci.yml`.
- **I5 Desktop acceptance.** GNOME Wayland + X11, GTK and Qt apps, a browser,
  a terminal. Same checklist as L6.
- **I6 Packaging.** Extend `linux/aur/PKGBUILD`; `.deb` later (see backlog in
  `linux-port.md`).

## Open questions

- Share one binary with fcitx5 or two? Two: the frameworks pull different
  libraries and users install one. Share only the C ABI and the key table.
- Lookup-table styling is not ours. If GNOME's list is too limited for the
  syllable-cursor flow (C8, C14), say so in the release notes rather than
  growing a panel of our own.
- Wayland sessions without an IBus-aware compositor path behave differently
  per desktop; test GNOME and KDE once before claiming support.

## Install (from source)

```sh
script/linux/build.sh           # builds build/ibus next to build/fcitx5
sudo cmake --install build/ibus # engine, component XML, libMisstypeCAPI.so
ibus restart                    # then add Misstype under Settings → Keyboard → Input Sources → Chinese
```

Settings: the engine reads the same ini file as the fcitx5 addon
(`$XDG_CONFIG_HOME/fcitx5/conf/misstype.conf`, edited by `misstypectl config`),
with the same keys and defaults; `MISSTYPE_CONFIG` overrides the path. Lone
Shift always toggles 中/英 (IBus has no competing Shift trigger), so
`ShiftTogglesEnglish` has no effect here.

- **Settings window** (`ibus-setup-misstype`, GTK4, `linux/ibus/tools/setup.c`):
  declared with `<setup>` in the component XML, so `ibus-setup` and GNOME
  Settings show a Preferences button for Misstype; run it directly otherwise.
  It owns no settings logic: it lists with `misstypectl config list` and writes
  with `misstypectl config set --no-reload`, so validation stays in the Zig
  core. Its rows mirror `settings` in `core-zig/src/ctl.zig`; keep them in
  step. Built only when GTK4 is present (the engine does not need it).
- **Live reload**: the engine watches the file (`config.c`), so a change from
  the window, `misstypectl config set` or an editor applies to running
  sessions within a fraction of a second, no `ibus restart`. Headless
  scenario LR5 rewrites the file under a running engine and checks the page
  size.
- Still not available: the candidate list's look (it is the shell's or
  `ibus-ui-gtk3`'s), and custom key bindings (also missing from the fcitx5 page).
