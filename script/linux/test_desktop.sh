#!/usr/bin/env bash
# Run inside the disposable dev container; installs only there, never the host.
# Uses the production GTK frontend and installed addon, not TestFrontend.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/desktop/no-swift
cat > build/desktop/no-swift/swift <<'NOSWIFT'
#!/usr/bin/env bash
echo 'desktop: shipping build unexpectedly requires Swift' >&2
exit 1
NOSWIFT
chmod +x build/desktop/no-swift/swift
export PATH="$PWD/build/desktop/no-swift:$PATH"
script/linux/build.sh
cmake --install build/fcitx5
mkdir -p build/desktop
cc -Wall -Wextra -Werror tests/capi/desktop.c $(pkg-config --cflags --libs gtk+-3.0) -o build/desktop/entry
export XDG_CONFIG_HOME="$PWD/build/desktop/config"
export XDG_DATA_HOME="$PWD/build/desktop/data"
export XDG_CACHE_HOME="$PWD/build/desktop/cache"
export XDG_RUNTIME_DIR="$PWD/build/desktop/runtime"
mkdir -p "$XDG_CONFIG_HOME/fcitx5" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
cat > "$XDG_CONFIG_HOME/fcitx5/profile" <<'PROFILE'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=misstype
[Groups/0/Items/0]
Name=keyboard-us
Layout=
[Groups/0/Items/1]
Name=misstype
Layout=
[GroupOrder]
0=Default
PROFILE
export GTK_IM_MODULE=fcitx XMODIFIERS=@im=fcitx DISPLAY=:99
# All processes share this isolated session bus.
trap 'status=$?; if [ "$status" -ne 0 ]; then cat build/desktop/{fcitx,gtk,xvfb}.log >&2; fi' EXIT
dbus-run-session -- bash -xeuo pipefail <<'SESSION'
Xvfb "$DISPLAY" -screen 0 1024x768x24 > build/desktop/xvfb.log 2>&1 &
xvfb_pid=$!
trap 'kill ${entry_pid:-} ${fcitx_pid:-} "$xvfb_pid" 2>/dev/null || true' EXIT
for _ in {1..50}; do if xdpyinfo >/dev/null 2>&1; then break; fi; sleep .1; done
fcitx5 --disable=classicui,notificationitem > build/desktop/fcitx.log 2>&1 &
fcitx_pid=$!
build/desktop/entry > build/desktop/commits.txt 2> build/desktop/gtk.log &
entry_pid=$!
window=$(timeout 15 xdotool search --sync --name 'Misstype desktop smoke' | head -1)
xdotool windowfocus --sync "$window"
for _ in {1..100}; do
    if fcitx5-remote -s misstype 2>/dev/null && [ "$(fcitx5-remote -n)" = misstype ]; then break; fi
    sleep .1
done
[ "$(fcitx5-remote -n)" = misstype ]
# First Return commits composition, second activates the GTK entry.
xdotool type --clearmodifiers --delay 100 'su3cl3'
xdotool key Return
sleep .3
xdotool key Return
for _ in {1..50}; do if [ -s build/desktop/commits.txt ]; then break; fi; sleep .1; done
printf '你好\n' | diff -u - build/desktop/commits.txt
# Clear committed text in the application, compose and edit via the IME.
xdotool key ctrl+a BackSpace
xdotool type --clearmodifiers --delay 100 'su3cl3'
xdotool key Left BackSpace
xdotool type --delay 100 'su3'
xdotool key Return
sleep .3
xdotool key Return
printf '你好\n你好\n' | diff -u - build/desktop/commits.txt
# Switch away, then confirm ordinary Latin delivery through GTK.
fcitx5-remote -c
xdotool key ctrl+a BackSpace
xdotool type --delay 100 'hello'
xdotool key Return
printf '你好\n你好\nhello\n' | diff -u - build/desktop/commits.txt
SESSION
# Verify installed CLI/settings and dictionary writes.
misstypectl config set CandidatesPerPage 7 --no-reload
[ "$(misstypectl config get CandidatesPerPage)" = 7 ]
misstypectl dict add ㄋㄧˇ-ㄏㄠˇ 你好
misstypectl dict check
# No Swift runtime in the production library or CLI.
library=$(sed -n '\|/misstype/libMisstypeCAPI.so$|p' build/fcitx5/install_manifest.txt)
test -f "$library"
ldd "$library" /usr/bin/misstypectl > build/desktop/dependencies.txt
if grep -Ei 'swift|not found' build/desktop/dependencies.txt; then cat build/desktop/dependencies.txt; exit 1; fi
echo 'PRODUCTION GTK DESKTOP SMOKE OK (Zig library + CLI)'
