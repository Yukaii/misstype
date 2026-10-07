---
name: misstype-linux-config
description: Configure Misstype and the fcitx5 around it on a Linux desktop — Misstype settings (selection keys, candidates per page, repair, learning, Shift 中/英), the candidate window (vertical list, theme, font), fcitx5 hotkeys, and which input methods are enabled. Use when the user asks to change how Misstype or fcitx5 behaves on Linux, e.g. "use 1-0 to pick candidates", "make the candidate box vertical", "let Shift switch English like on macOS", "add Misstype to my input methods".
---

# Configure Misstype on Linux (fcitx5)

Misstype is an fcitx5 addon. Three layers hold its configuration; change each
through the running fcitx5 so the change is live and is not overwritten
(fcitx5 rewrites its config files from memory when it saves or exits, so a
file edited behind its back can be lost).

| What | Where it lives | How to change it |
|---|---|---|
| Misstype settings | `~/.config/fcitx5/conf/misstype.conf` | `misstypectl config …` (reloads the addon) |
| Candidate window look | `~/.config/fcitx5/conf/classicui.conf` | edit, then `ReloadAddonConfig classicui` |
| fcitx5 hotkeys, behavior | `~/.config/fcitx5/config` | D-Bus `SetConfig fcitx://config/global` |
| Enabled input methods | `~/.config/fcitx5/profile` | D-Bus `SetInputMethodGroupInfo`, then `Save` |

Before changing anything, read the current value, and back up a file you are
about to write (`cp f f.bak-<what>`). Afterwards, read the value back from
the running fcitx5 (see Verify) — a file that changed is not proof that
fcitx5 picked it up.

## Check the setup first

```sh
pacman -Q fcitx5-misstype-git 2>/dev/null || dpkg -l | grep -i misstype   # installed?
pgrep -a fcitx5                                                           # running? note its flags
command -v misstypectl
```

If fcitx5 does not list Misstype after an install, restart it with the flags
it was running with: `setsid -f fcitx5 -r -d <same flags> >/dev/null 2>&1`.

## Misstype settings

```sh
misstypectl config list            # every key, current value, (default) marks
misstypectl config get CandidateKeys
misstypectl config set <Key> <value>
misstypectl config reset <Key>
```

`set` validates the value and asks fcitx5 over D-Bus to reload the addon.
Keys (same as the settings page in `fcitx5-configtool`):

- `CandidateKeys` — selection keys, e.g. `asdfghjkl;` (default) or
  `1234567890`. Distinct keys of the Zhuyin layout, at most 10. They pick a
  candidate only in selection mode (Tab/Down/syllable cursor); elsewhere they
  type Zhuyin (`1` = ㄅ), so number keys are safe.
- `CandidatesPerPage` — 4–10 (default 8). Only the first N selection keys are
  used: set 10 together with `1234567890`, or `0` is never shown.
- `RepairStrength` — Off/Light/Standard/Strong. `ToneTolerance`,
  `UserLearning`, `ChannelLearning`, `MixedEnglish`, `AutoShowCandidates`,
  `ReturnConfirmsSelection` — on/off. `CursorCandidates` —
  Covering/EndingAt/BeginningAt. `AutoCommitSyllables` — 0–64.
- `ShiftTogglesEnglish` — on: a lone Shift tap switches 中/英 inside Misstype
  (macOS behavior; mid-composition it opens an English run). Requires
  clearing fcitx5's AltTriggerKeys (below), because fcitx5 handles that key
  before Misstype sees it. Off (default): lone Left Shift is fcitx5's
  "temporarily switch to the first input method".

If `misstypectl` reports it could not reach fcitx5, the value still applies
on next start, or reload now:
`busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 ReloadAddonConfig s misstype`.

## Candidate window (classicui)

Keys in `~/.config/fcitx5/conf/classicui.conf` (one `Key=Value` per line;
create the file if missing, keep other lines): `Vertical Candidate List=True`,
`Font="Sans 13"`, `Theme=<name>`, `DarkTheme=<name>`,
`UseDarkTheme=True`, `PerScreenDPI=True`. Then:

```sh
busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 ReloadAddonConfig s classicui
```

If a desktop panel (KDE's kimpanel) draws candidates instead of classicui,
its own settings decide orientation.

## fcitx5 hotkeys (global config)

Read: `busctl --user --json=short call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 GetConfig s fcitx://config/global`
(values under `data[0].data.Hotkey.data`). Write a partial config; omitted
keys keep their values. Clear AltTriggerKeys (needed for `ShiftTogglesEnglish`):

```sh
busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetConfig sv \
  fcitx://config/global 'a{sv}' 1 Hotkey 'a{sv}' 1 AltTriggerKeys 'a{sv}' 0
```

Restore it: `… AltTriggerKeys 'a{sv}' 1 0 s Shift_L`. Other lists work the
same way: `TriggerKeys` (default Control+space), `EnumerateForwardKeys`.

## Enabled input methods

```sh
busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 InputMethodGroupInfo s Default
# -> "us" 2 "keyboard-us" "" "chewing" ""   (layout, then (im, layout) pairs)
busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetInputMethodGroupInfo 'ssa(ss)' \
  Default us 3 keyboard-us "" chewing "" misstype ""
busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 Save
```

Pass the full list (existing entries plus the new one); the first entry is
the "inactive" layout the trigger key toggles back to.

## Verify

```sh
busctl --user --json=short call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 \
  GetConfig s fcitx://config/addon/misstype | python3 -c \
  'import json,sys; d=json.load(sys.stdin)["data"][0]["data"]; print({k:v["data"] for k,v in d.items()})'
```

Use `fcitx://config/addon/classicui` or `fcitx://config/global` the same way.
Then ask the user to try it: type `su3cl3`, press Tab, and check the labels
and orientation of the candidate list.

## Don'ts

- Do not edit `~/.config/fcitx5/profile` or `config` while fcitx5 runs and
  leave it at that; use the D-Bus calls above (or reload immediately).
- Do not log or quote what the user types; `~/.local/share/misstype/` holds
  their dictionary and learning data — read it only when asked.
