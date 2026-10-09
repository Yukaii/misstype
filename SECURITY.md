# Security policy

Misstype is an input method: it sees everything a user types and the macOS
build updates itself. Reports about key handling, data leaving the device,
the update path or the packaging are welcome.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Use GitHub's
private reporting instead:
<https://github.com/Yukaii/misstype/security/advisories/new>

Include what you saw, the version (Settings → About, or the release tag),
the platform (macOS IME, Linux fcitx5, web demo), and a reproduction. If it
involves typed text or a trace, use synthetic or redacted text; do not send
real personal input.

This is a small, volunteer-run project. I aim to acknowledge a report within
a week and will coordinate a fix and disclosure timing with you. There is no
bug bounty.

## Supported versions

Only the latest release receives security fixes. The macOS IME updates itself
through Sparkle; Linux users update via their package or `script/linux/install_ime.sh`.

## What is in scope

- The Zig core (`core-zig/`), the macOS IMK adapter and installer, the Linux
  fcitx5 addon, `misstypectl`, and the website demo.
- The update and release path: Sparkle appcast and EdDSA-signed archives,
  the release workflows in `.github/workflows/`.
- Anything that sends typed text or traces off the device. The default is
  that nothing does (`AGENTS.md`, Data and privacy).

## Out of scope

- Third-party components (Sparkle, fcitx5, utf8proc, upstream dictionaries):
  report those upstream; tell us if our pinned version needs bumping.
- Issues needing an already-compromised user account or local root.
- Mistakes in decoding results that are not a safety or privacy problem; file
  those as normal bugs.
