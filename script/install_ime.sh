#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
./script/build_and_run.sh --build-only
DEST="$HOME/Library/Input Methods/MistypeIME.app"
mkdir -p "$(dirname "$DEST")"
# Keep one rollback copy when replacing our own input method.
if [[ -d "$DEST" ]]; then
  /usr/bin/ditto "$DEST" "$ROOT_DIR/.cache/MistypeIME-previous.app"
  rm -rf "$DEST"
fi
/usr/bin/ditto "$ROOT_DIR/dist/MistypeIME.app" "$DEST"
BIN_DIR="$(swift build -c release --show-bin-path)"
"$BIN_DIR/MistypeSourceTool" register "$DEST"
"$BIN_DIR/MistypeSourceTool" select
echo "Installed Mistype. Select it from the macOS input-source menu to try it."
