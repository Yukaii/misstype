#!/bin/zsh
# Build the release artifacts for one version:
#
#   dist/Mistype-<v>.dmg         DMG holding "Install Mistype.app" (per-user installer)
#   dist/MistypeIME-<v>.zip      Sparkle update archive (the signed MistypeIME.app)
#   dist/appcast.xml             Sparkle feed for that archive (needs SPARKLE_ED_KEY_FILE)
#   dist/*.sha256
#
#   ./script/package_release.sh 0.2.0
#
# Environment (all optional; without signing the output is ad-hoc signed and
# Gatekeeper blocks the DMG itself on other machines, though the installed
# copy carries no quarantine flag):
#   SIGN_IDENTITY       codesign identity, e.g. "Developer ID Application: …"
#   BUILD_NUMBER        CFBundleVersion, must increase every release (default 1)
#   NOTARY_KEY_PATH     App Store Connect API key (.p8) for notarytool
#   NOTARY_KEY_ID       its key ID
#   NOTARY_ISSUER_ID    its issuer ID
#   SPARKLE_PUBLIC_KEY  EdDSA public key baked into the app (default: the
#                       contents of Resources/SparklePublicKey.txt). Without
#                       one the IME ships with updates disabled.
#   SPARKLE_ED_KEY_FILE file with the matching private key; enables appcast.xml
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:?usage: package_release.sh <version>}"
VERSION="${VERSION#v}"
IDENTITY="${SIGN_IDENTITY:--}"
BUILD="${BUILD_NUMBER:-1}"
APP_DIR="$ROOT_DIR/dist/MistypeIME.app"
INSTALLER_DIR="$ROOT_DIR/dist/Install Mistype.app"
DMG="$ROOT_DIR/dist/Mistype-$VERSION.dmg"
ZIP="$ROOT_DIR/dist/MistypeIME-$VERSION.zip"
ARCHS="--arch arm64 --arch x86_64"

SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-$(cat Resources/SparklePublicKey.txt 2>/dev/null || true)}"

set_version() {  # <Info.plist>
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$1"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$1"
}

notarize() {
  if [[ -z "${NOTARY_KEY_ID:-}" ]]; then
    echo "NOTARY_KEY_ID unset; skipping notarization of $1" >&2
    return
  fi
  xcrun notarytool submit "$1" --wait \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
}

# --- The input method -------------------------------------------------------
SWIFT_BUILD_FLAGS="$ARCHS" ./script/build_and_run.sh --build-only
set_version "$APP_DIR/Contents/Info.plist"
if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP_DIR/Contents/Info.plist"
else
  echo "No Sparkle public key: this build will not check for updates." >&2
fi
./script/sign_bundle.sh "$IDENTITY" "$APP_DIR" Resources/Mistype.entitlements

# Notarize and staple the app itself so it passes Gatekeeper offline.
if [[ -n "${NOTARY_KEY_ID:-}" ]]; then
  NOTARIZE_ZIP="$ROOT_DIR/dist/MistypeIME-notarize.zip"
  /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$NOTARIZE_ZIP"
  notarize "$NOTARIZE_ZIP"
  rm -f "$NOTARIZE_ZIP"
  xcrun stapler staple "$APP_DIR"
fi

# Sparkle update archive: made after stapling so updates carry the ticket.
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP"

# --- The installer app ------------------------------------------------------
swift build -c release $=ARCHS --product MistypeInstaller
INSTALLER_BIN="$(swift build -c release $=ARCHS --show-bin-path)/MistypeInstaller"
rm -rf "$INSTALLER_DIR"
mkdir -p "$INSTALLER_DIR/Contents/MacOS" "$INSTALLER_DIR/Contents/Resources"
cp "$INSTALLER_BIN" "$INSTALLER_DIR/Contents/MacOS/MistypeInstaller"
cp Resources/Installer/Info.plist "$INSTALLER_DIR/Contents/Info.plist"
cp Resources/MistypeIcon.png "$INSTALLER_DIR/Contents/Resources/"
cp -R Resources/Installer/*.lproj "$INSTALLER_DIR/Contents/Resources/"
/usr/bin/ditto "$APP_DIR" "$INSTALLER_DIR/Contents/Resources/MistypeIME.app"
set_version "$INSTALLER_DIR/Contents/Info.plist"
./script/sign_bundle.sh "$IDENTITY" "$INSTALLER_DIR"

# --- DMG --------------------------------------------------------------------
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$INSTALLER_DIR" "$STAGING/Install Mistype.app"
rm -f "$DMG"
hdiutil create -volname "Mistype $VERSION" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
if [[ "$IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --sign - "$DMG"
else
  /usr/bin/codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi
if [[ -n "${NOTARY_KEY_ID:-}" ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

# --- Feed and checksums -----------------------------------------------------
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  ./script/make_appcast.sh "$VERSION" "$BUILD" "$ZIP"
fi
(cd dist && for f in "$(basename "$DMG")" "$(basename "$ZIP")"; do shasum -a 256 "$f" > "$f.sha256"; done)
echo "Packaged $DMG and $ZIP"
