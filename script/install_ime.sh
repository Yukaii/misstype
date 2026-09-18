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
killall -9 MistypeIME 2>/dev/null || true
killall TextInputMenuAgent TextInputSwitcher 2>/dev/null || true

# Register with LaunchServices and clean up dist duplicate
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$ROOT_DIR/dist/MistypeIME.app" 2>/dev/null || true
  "$LSREGISTER" -f "$DEST"
fi

sleep 0.5
BIN_DIR="$(swift build -c release --show-bin-path)"
"$BIN_DIR/MistypeSourceTool" register "$DEST"
"$BIN_DIR/MistypeSourceTool" select

# Do NOT launch the binary by hand here. TIS launches and supervises the IME
# on demand when the input source is selected; a manually started copy squats
# the InputMethodConnectionName Mach service, so the TIS-launched instance
# fails IMKServer init and exits — leaving the source selected but dead.
echo "Installed Mistype. Select it from the macOS input-source menu to try it."
