#!/bin/zsh
# Sign an app bundle inside-out: nested code under Contents/Frameworks first
# (Sparkle's helpers, then each framework), then the app itself. Never --deep:
# it signs in the wrong order and hides which component failed.
#
#   ./script/sign_bundle.sh <identity|-> <Foo.app> [entitlements.plist]
#
# The entitlements apply to the app only; Sparkle's helpers keep their own.
#
# "-" is ad-hoc (development). A real identity gets the hardened runtime and a
# secure timestamp, which notarization requires.
set -euo pipefail
IDENTITY="${1:?usage: sign_bundle.sh <identity|-> <bundle> [entitlements]}"
APP="${2:?usage: sign_bundle.sh <identity|-> <bundle> [entitlements]}"
ENTITLEMENTS="${3:-}"

if [[ "$IDENTITY" == "-" ]]; then
  OPTS=(--force --sign -)
else
  OPTS=(--force --sign "$IDENTITY" --options runtime --timestamp)
fi

for framework in "$APP"/Contents/Frameworks/*.framework(N); do
  # Sparkle's helpers live in Versions/B. Installer.xpc is needed because the
  # app is sandboxed (Downloader.xpc is removed at embed time).
  for nested in "$framework"/Versions/*/XPCServices/*.xpc(N) \
                "$framework"/Versions/*/Autoupdate(N) "$framework"/Versions/*/Updater.app(N); do
    /usr/bin/codesign "${OPTS[@]}" "$nested"
  done
  /usr/bin/codesign "${OPTS[@]}" "$framework"
done
if [[ -n "$ENTITLEMENTS" ]]; then OPTS+=(--entitlements "$ENTITLEMENTS"); fi
/usr/bin/codesign "${OPTS[@]}" "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
