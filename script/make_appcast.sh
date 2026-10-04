#!/bin/zsh
# Write dist/appcast.xml for one Sparkle update archive. The feed lists only
# the newest release: the app's SUFeedURL is
# .../releases/latest/download/appcast.xml, so GitHub serves the newest
# non-prerelease's copy and older versions never need to stay in the file.
#
#   SPARKLE_ED_KEY_FILE=key.txt ./script/make_appcast.sh 0.2.0 7 dist/MistypeIME-0.2.0.zip
#
# SPARKLE_ED_KEY_FILE holds the private key printed by Sparkle's
# `generate_keys -x`. It never enters the repo; CI writes it from a secret.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:?usage: make_appcast.sh <version> <build> <archive.zip>}"
BUILD="${2:?usage: make_appcast.sh <version> <build> <archive.zip>}"
ARCHIVE="${3:?usage: make_appcast.sh <version> <build> <archive.zip>}"
VERSION="${VERSION#v}"
REPO="${GITHUB_REPOSITORY:-Yukaii/misstype}"
TAG="${TAG:-v$VERSION}"
KEY_FILE="${SPARKLE_ED_KEY_FILE:?SPARKLE_ED_KEY_FILE is not set}"

SIGN_UPDATE="$(find .build/artifacts -type f -name sign_update -perm -u+x | head -1)"
[[ -x "$SIGN_UPDATE" ]] || { echo "sign_update not found; run swift build first" >&2; exit 1; }
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$ARCHIVE")"

cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Misstype</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$(basename "$ARCHIVE")" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML
echo "Wrote dist/appcast.xml"
