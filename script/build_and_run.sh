#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="MistypeIME"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then killall "$APP_NAME" || true; fi
python3 script/prepare_lexicon.py
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/MistypeIcon.png "$APP_DIR/Contents/Resources/MistypeIcon.png"
cp Resources/MistypeMenuIcon.tiff "$APP_DIR/Contents/Resources/MistypeMenuIcon.tiff"
cp -R Resources/en.lproj Resources/zh-Hant.lproj "$APP_DIR/Contents/Resources/"
cp .cache/mcbopomofo/lexicon.tsv "$APP_DIR/Contents/Resources/lexicon.tsv"
cp Resources/local_phrases.tsv "$APP_DIR/Contents/Resources/local_phrases.tsv"
cp -R third_party "$APP_DIR/Contents/Resources/third_party"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP_DIR/Contents/Resources/"
/usr/bin/codesign --force --sign - "$APP_DIR"
/usr/bin/codesign --verify --strict "$APP_DIR"
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
if [[ "${1:-}" == "--verify" ]]; then
  /usr/bin/open -n "$APP_DIR"
  sleep 3
  pgrep -x "$APP_NAME" >/dev/null
else
  /usr/bin/open -n "$APP_DIR"
fi
