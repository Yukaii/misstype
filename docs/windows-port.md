# Windows port (TSF): sketch

Status (2026-10-10): **sketch, not started.** Drafted after deciding the
platform order in `docs/cross-platform.md` (Platform priority). Nothing here
is verified on a machine yet. Items marked **spike** must be settled before
committing to a task, and they are mostly API facts to confirm against the
Microsoft docs and a real Windows build.

**Goal:** Misstype runs on Windows as a Text Services Framework (TSF) text
service with the same behavior as macOS and Linux, over the same C ABI,
conformant on C1–C15 (`docs/cross-platform.md`).

**Non-goals for v1:** the legacy IMM32 API, a Windows-native settings app beyond
what the shared config files allow, store distribution, touch keyboard
integration (that belongs to the touch track).

## Why TSF

TSF is the supported IME framework on Windows (Weasel/Rime, Microsoft's own
IMEs and PIME build on it). It is also the only way to type into modern UWP
and secure-desktop-adjacent surfaces. IMM32 would be a dead end.

## What the core already gives us

- `x86_64-windows` is an existing Zig cross-compile target (`docs/zig-port.md`,
  6–9 s). `x86-windows` and `aarch64-windows` need the same check (**spike**).
- The core needs only libc-level runtime, so `MisstypeCAPI.dll` ships next to
  the text service with no runtime installer.
- The C ABI already carries what a composition needs: `preedit` with caret in
  UTF-16 (TSF ranges are UTF-16, so `caret_utf16`, `segments_utf16` and the
  mark range apply directly), the candidate list with `selected` and
  `page_size`, `consumed` / `commit`.

## Mapping onto the contract

| Contract | TSF |
| --- | --- |
| Key translation §1 | `ITfKeyEventSink::OnTestKeyDown/OnKeyDown/OnTestKeyUp/OnKeyUp`. Use the **scan code** from `lParam` (positional, layout independent; 大千 is positional) through a new core table `misstype_key_from_windows_scancode` (set 1 scan codes plus the extended bit). Fallback to `misstype_key_from_character` on `ToUnicodeEx` output for synthetic events. |
| Modifiers after the event | build from `GetKeyState`, then correct for the key being processed (same pattern as fcitx5). |
| Deliver iff `consumed` | `OnTestKeyDown` must predict what `OnKeyDown` will do, but the session is stateful and a test call must not mutate it. **Spike:** run the session once in `OnTestKeyDown`, cache the result, and replay it in `OnKeyDown` (keyed by event); or a dry-run entry point in the core (preferred only if the cache proves fragile). |
| Commit | edit session (`ITfEditSession` via `RequestEditSession`): `SetText` on the composition range, then `EndComposition`. |
| Preedit §3 | composition (`ITfCompositionSink`, `StartComposition`), display attributes from `segments` (underline per word) and the mark range (**spike**: `ITfDisplayAttributeProvider` registration). Caret = selection set inside the composition range. |
| Candidates | our own top-level window positioned from `ITfContextView::GetTextExt`, **plus** `ITfCandidateListUIElement` / `ITfUIElementSink` so UI-less hosts and the immersive shell can draw it. v1: own window only; add the UI-element path for UWP in W5. |
| Row click | window message → `misstype_session_pick` on the UI thread. |
| Lifecycle §4 | `ITfTextInputProcessorEx::ActivateEx` / `Deactivate`; `ITfThreadMgrEventSink::OnSetFocus` → `reset_modifiers`; focus loss, `OnCompositionTerminated`, language-profile switch → `commit()`. One engine per process, one session per `ITfContext`. |
| Threading §5 | TSF calls arrive on the host's UI thread. One engine per host process, so the core's learning files can be contended across processes: see Data. |
| Data §6 | per-user `%APPDATA%\Misstype` (or `%LOCALAPPDATA%`) for `user_dictionary.tsv`, `user_phrases.json`, `channel_model.json`. The lexicon sits beside the DLL under `Program Files` or the per-user install dir. **Spike:** AppContainer/UWP hosts cannot read arbitrary user files; Weasel-style installs grant the `ALL APPLICATION PACKAGES` SID read access to the lexicon directory. |
| Settings | the same key=value config as Linux (`misstypectl config` builds for Windows), plus a small Win32 or WinUI dialog later. |

## Build and install facts to confirm (spike)

- A TSF DLL is loaded **into every host process**, so a 64-bit and a 32-bit
  build are both needed (32-bit apps still exist), and an ARM64 build for ARM
  Windows. Registration in the registry: CLSID, TIP profile, categories
  (`GUID_TFCAT_TIP_KEYBOARD`, `GUID_TFCAT_TIPCAP_UIELEMENTENABLED`,
  `GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT`, `GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT`).
- Install needs elevation (system-wide COM registration), unlike the macOS
  per-user installer. Decide: an MSI/Inno installer vs a `regsvr32` script for
  developers first.
- Code signing: unsigned DLLs trigger SmartScreen and some hosts refuse them;
  plan for the same release workflow as macOS (`.github/workflows/release.yml`)
  with an Authenticode step.
- Language choice for the text service shell (the one real decision, see
  below).

## Tasks

- **W0 Spike (a few days, needs a Windows machine or `windows-latest` + a VM).**
  A do-nothing TSF text service that registers, shows in the language bar,
  receives key events in Notepad, and starts/ends a composition. Settles: key
  event numbering, `OnTestKeyDown` strategy, UWP behavior, the language
  choice.
- **W1 Core pieces.** `misstype_key_from_windows_scancode` in `capi.zig`
  with a unit test in `keymap_test.zig`; Windows cross-build of the C ABI
  (x64, x86, arm64) in `zig build` and CI; `misstypectl` for Windows.
- **W2 Text service.** Key sink, composition, edit sessions, lifecycle,
  config and data paths.
- **W3 Candidate window.** Own window, no focus steal, DPI aware, positions
  from `GetTextExt`; rows only (per the AGENTS.md adapter lesson).
- **W4 Conformance.** TSF has no headless frontend. Split it: the adapter's
  pure parts (scancode/modifier translation, view → composition ranges) are
  unit-tested natively; C1–C15 run at the C ABI level on `windows-latest` as a
  harness DLL load; and a UI Automation pass types into Notepad on a VM
  (manual acceptance until it is scripted).
- **W5 UWP and secure surfaces.** UI-element path and AppContainer access.
- **W6 Installer, signing, release.** Extend `release.yml`; document in
  `docs/release.md`.

## Decisions (2026-10-10, owner: user)

- **Shell language: C++.** The core and C ABI stay Zig. Build the text
  service with MSVC or clang-cl on the `windows-latest` runner.
- **Testing: CI first, VM later.** There is no Windows machine for now. Until
  the build succeeds and the basics look right, everything is verified by CI
  only: Windows builds (x64, x86, arm64), native unit tests, and C1–C15 at the
  C ABI level. The owner sets up a VM afterwards for the manual Notepad / UWP
  acceptance (W4, W5).
- **Scope of v1.** Zhuyin only, with the `mixedEnglish` default matching the
  other platforms (off).

Consequences for the plan:

- **W0 changes:** the spike cannot start with a hands-on session. Run it as a
  CI job: build a do-nothing text service, register it on the runner with
  `regsvr32`, and drive key events through the TSF APIs or UI Automation
  against Notepad. If CI cannot do that, W0's interactive checks wait for the
  VM, while W1 (core table and Windows cross-builds) proceeds regardless.
- Anything that needs a real session (language bar, UWP, candidate window
  placement, DPI) is marked **unverified** in the docs and the PR until the
  VM pass, per the Definition of done in `AGENTS.md`.
