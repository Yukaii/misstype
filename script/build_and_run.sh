#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="MisstypeIME"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
if [[ "${1:-}" != "--build-only" ]] && pgrep -x "$APP_NAME" >/dev/null 2>&1; then killall "$APP_NAME" || true; fi
python3 script/prepare_lexicon.py
# The IMK target links the Zig C ABI; build its universal dylib before SwiftPM
# resolves the macOS bridge target.
script/zig/build_macos.sh
# SWIFT_BUILD_FLAGS lets release packaging add e.g. "--arch arm64 --arch x86_64".
BUILD_FLAGS=(-c release ${=SWIFT_BUILD_FLAGS:-})
swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
# Keep the complete Sparkle notices (including its bundled components) in
# sync with the resolved binary artifact before packaging anything.
cmp third_party/Sparkle/LICENSE .build/artifacts/sparkle/Sparkle/LICENSE
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/MisstypeIcon.png "$APP_DIR/Contents/Resources/MisstypeIcon.png"
cp Resources/MisstypeMenuIcon.tiff "$APP_DIR/Contents/Resources/MisstypeMenuIcon.tiff"
cp -R Resources/*.lproj "$APP_DIR/Contents/Resources/"
cp .cache/mcbopomofo/lexicon.tsv "$APP_DIR/Contents/Resources/lexicon.tsv"
cp .cache/mcbopomofo/toneless.tsv "$APP_DIR/Contents/Resources/toneless.tsv"
cp Resources/local_phrases.tsv "$APP_DIR/Contents/Resources/local_phrases.tsv"
cp .cache/frequencywords/english.tsv "$APP_DIR/Contents/Resources/english.tsv"
cp -R third_party "$APP_DIR/Contents/Resources/third_party"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP_DIR/Contents/Resources/"
mkdir -p "$APP_DIR/Contents/Frameworks"
cp dist/zig/macos-universal/libMisstypeCAPI.dylib "$APP_DIR/Contents/Frameworks/"

# Sparkle.framework: SwiftPM drops it next to the products; the artifact
# bundle is the fallback. The app is sandboxed (Resources/Misstype.entitlements),
# so Installer.xpc stays; Downloader.xpc is dropped because the app already
# holds the network.client entitlement.
SPARKLE_FW="$BIN_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE_FW" ]]; then
  SPARKLE_FW="$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' | head -1)"
fi
[[ -d "$SPARKLE_FW" ]] || { echo "Sparkle.framework not found; did swift build resolve packages?" >&2; exit 1; }
/usr/bin/ditto "$SPARKLE_FW" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP_DIR"/Contents/Frameworks/Sparkle.framework/Versions/*/XPCServices/Downloader.xpc

./script/sign_bundle.sh - "$APP_DIR" Resources/Misstype.entitlements
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
if [[ "${1:-}" == "--verify" ]]; then
  /usr/bin/open -n "$APP_DIR"
  sleep 3
  pgrep -x "$APP_NAME" >/dev/null
else
  /usr/bin/open -n "$APP_DIR"
fi
