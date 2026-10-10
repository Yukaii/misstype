#!/usr/bin/env bash
# IBus adapter check (runs inside the container): builds libMisstypeCAPI.so and
# the engine, starts a private ibus-daemon on a private session bus (Xvfb for
# the daemon's X dependency), runs the engine and the headless conformance
# client (C1-C15, LR1-LR3) against the 7-line fixture lexicon. Needs no
# network and no real display.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ "${1:-}" != --inner ]; then
    script/linux/build_capi.sh
    BIN_DIR=$(cat build/capi/libdir)
    cmake -S linux/ibus -B build/ibus \
        -DMISSTYPE_CAPI_DIR="$BIN_DIR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
    cmake --build build/ibus -j"$(nproc)"
    [ -s /etc/machine-id ] || dbus-uuidgen > /etc/machine-id
    exec xvfb-run -a dbus-run-session -- bash "$0" --inner
fi

# Inside the private session bus.
ROOT=$PWD
HOME=$(mktemp -d)
export HOME XDG_DATA_HOME=$HOME/data XDG_CONFIG_HOME=$HOME/config
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
# The conformance scenarios assume the core's defaults, not the settings page's,
# and C4's pick must not teach the decoder (later scenarios expect 你).
printf 'UserLearning=False\nMixedEnglish=True\nAutoShowCandidates=True\nReturnConfirmsSelection=False\n' > "$HOME/conformance.conf"
export MISSTYPE_CONFIG=$HOME/conformance.conf MISSTYPE_RESOURCES=$ROOT/tests/fixtures/lexicon

cleanup() {
    [ -n "${engine_pid:-}" ] && kill "$engine_pid" 2>/dev/null || true
    ibus exit 2>/dev/null || true
}
trap cleanup EXIT

ibus-daemon --daemonize --replace --panel disable --cache none
# The address file appears before the daemon accepts connections: wait for a real reply.
for _ in $(seq 100); do ibus list-engine >/dev/null 2>&1 && break; sleep 0.2; done

"$ROOT/build/ibus/ibus-engine-misstype" &
engine_pid=$!
sleep 1
kill -0 "$engine_pid" || { echo "the misstype engine exited" >&2; exit 1; }

"$ROOT/build/ibus/test-misstype-ibus"
