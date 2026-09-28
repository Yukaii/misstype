#!/bin/zsh
# Build a universal MistypeIME.app and wrap it in a distributable DMG.
#
#   ./script/package_release.sh 0.2.0
#
# Environment (all optional; without them the output is ad-hoc signed and
# Gatekeeper will block it on other machines):
#   SIGN_IDENTITY     codesign identity, e.g. "Developer ID Application: …"
#   BUILD_NUMBER      CFBundleVersion (default 1)
#   NOTARY_KEY_PATH   App Store Connect API key (.p8) for notarytool
#   NOTARY_KEY_ID     its key ID
#   NOTARY_ISSUER_ID  its issuer ID
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:?usage: package_release.sh <version>}"
VERSION="${VERSION#v}"
IDENTITY="${SIGN_IDENTITY:--}"
APP_DIR="$ROOT_DIR/dist/MistypeIME.app"
DMG="$ROOT_DIR/dist/Mistype-$VERSION.dmg"

SWIFT_BUILD_FLAGS="--arch arm64 --arch x86_64" ./script/build_and_run.sh --build-only

PLIST="$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$PLIST"

sign() {
  if [[ "$IDENTITY" == "-" ]]; then
    /usr/bin/codesign --force --sign - "$@"
  else
    # Notarization requires the hardened runtime and a secure timestamp.
    /usr/bin/codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"
  fi
}

notarize() {
  if [[ -z "${NOTARY_KEY_ID:-}" ]]; then
    echo "NOTARY_KEY_ID unset; skipping notarization of $1" >&2
    return
  fi
  xcrun notarytool submit "$1" --wait \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
}

sign "$APP_DIR"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_DIR"

# Notarize and staple the app itself so it passes Gatekeeper offline once
# copied out of the DMG; then notarize the DMG that wraps it.
if [[ -n "${NOTARY_KEY_ID:-}" ]]; then
  ZIP="$ROOT_DIR/dist/MistypeIME-notarize.zip"
  /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP_DIR"
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$APP_DIR" "$STAGING/MistypeIME.app"
ln -s "/Library/Input Methods" "$STAGING/Input Methods"
rm -f "$DMG"
hdiutil create -volname "Mistype $VERSION" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
sign "$DMG"
if [[ -n "${NOTARY_KEY_ID:-}" ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Packaged $DMG"
