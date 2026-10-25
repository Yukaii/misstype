# Misstype for Obsidian

Try Misstype without installing an input method: the plugin runs the same Zig
decoder (WebAssembly, `misstype-wasm`) inside Obsidian on desktop and mobile.
Type Zhuyin (Dachen layout) and it turns into Chinese, with typo and missing-tone
repair. A lone Shift tap switches 中/英. Everything is offline: the lexicons are
embedded in `main.js`, and nothing typed leaves the device.

- **Hardware keyboard** (desktop, iPad with a keyboard): keys are read before
  the editor sees them; the pre-edit and candidates float at the caret. Works in
  notes and in Obsidian's text fields (search, rename, …).
- **Phone / tablet without a keyboard**: while a note is being edited, an
  on-screen Zhuyin keyboard (the site editor's, `site/editor/keyboard.js`)
  replaces the system one. The command *Switch between the Zhuyin and the system
  keyboard* (add it to the mobile toolbar) gives the system keyboard back. It
  steps aside by itself once a hardware keyboard is used.

The user dictionary (Shift+←/→ marks a phrase, Enter files it) and learned
picks are kept per vault in this device's local storage, not in the vault.

## Build and install

```sh
script/build_site_assets.sh            # wasm + lexicons into site/public (pinned public sources)
cd packages/obsidian-misstype
npm install
npm run build                          # dist/main.js, manifest.json, styles.css
npm run install-vault -- /path/to/vault   # copies dist/ into <vault>/.obsidian/plugins/misstype/
npm test                               # embedded assets decode and drive the decoder
```

Then enable **Misstype** under Settings → Community plugins. For a phone, install
into a vault that syncs to it (Obsidian Sync, iCloud), or copy the three files
into `.obsidian/plugins/misstype/` there; restart Obsidian on the phone.

## Limits

- Tested headless only (asset pipeline). The keyboard layout on Obsidian's
  mobile UI (`.app-container` height, the mobile toolbar) needs a device check.
- The candidate window floats at the caret; on a phone it is not docked above
  the keyboard as in the site editor.
- Without a hardware keyboard only notes get the Zhuyin keyboard; other text
  fields keep the system keyboard.
- Not in the community plugin directory: it expects `manifest.json` at the root
  of a repository of its own.
