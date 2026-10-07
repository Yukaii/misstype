#!/usr/bin/env bash
# Builds Misstype from this checkout and installs it for desktop testing: the
# Linux counterpart of script/install_ime.sh.
#   Arch:      a pacman package from linux/aur/PKGBUILD at the checked-out
#              commit (committed code only), installed with pacman -U.
#   elsewhere: script/linux/build.sh, then cmake --install to /usr.
# Then restarts a running fcitx5 (same flags) and adds Misstype to the current
# input-method group if it is missing.
#
#   script/linux/install_ime.sh [--check] [--build-only]
#     --check       also run the test suites (makepkg check / test_all.sh)
#     --build-only  build, do not install or restart anything
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

CHECK=0
BUILD_ONLY=0
for arg in "$@"; do
    case $arg in
    --check) CHECK=1 ;;
    --build-only) BUILD_ONLY=1 ;;
    -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

FCITX=(busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1)

if command -v pacman >/dev/null && command -v makepkg >/dev/null; then
    HEAD=$(git rev-parse HEAD)
    if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
        echo "note: uncommitted changes are not built (makepkg builds $(git rev-parse --short HEAD))" >&2
    fi
    # Kept between runs (.cache is ignored): makepkg reuses the clone and
    # SwiftPM's .build there, so a rebuild is incremental.
    BUILDDIR="$ROOT/.cache/aur-build"
    mkdir -p "$BUILDDIR"
    cp linux/aur/PKGBUILD linux/aur/cxx20.patch "$BUILDDIR/"
    flags=(-f --syncdeps --noconfirm)
    [[ $CHECK == 1 ]] || flags+=(--nocheck)
    export MISSTYPE_SOURCE_URL="file://$ROOT#commit=$HEAD"
    # zstd: the xz default spends minutes compressing the Swift library.
    export PKGEXT=.pkg.tar.zst
    (cd "$BUILDDIR" && makepkg "${flags[@]}")
    PKG=$(cd "$BUILDDIR" && makepkg --packagelist | head -n1)
    echo "Built $PKG"
    [[ $BUILD_ONLY == 1 ]] && exit 0
    sudo pacman -U "$PKG"
else
    [[ $CHECK == 1 ]] && bash script/linux/test_all.sh
    bash script/linux/build.sh
    [[ $BUILD_ONLY == 1 ]] && exit 0
    sudo cmake --install build/fcitx5
fi

# Restart fcitx5 so it loads the new addon, keeping the flags it ran with.
pid=$(pgrep -u "$(id -u)" -x fcitx5 | head -n1 || true)
if [[ -z $pid ]]; then
    echo "Installed Misstype. fcitx5 is not running: start it (or log in again), then add Misstype in fcitx5-configtool."
    exit 0
fi
args=()
while IFS= read -r -d '' a; do
    case $a in -r | --replace | -d) ;; *) args+=("$a") ;; esac
done < <(tail -z -n +2 "/proc/$pid/cmdline")
setsid -f fcitx5 -r -d "${args[@]}" >/dev/null 2>&1
for _ in $(seq 40); do
    sleep 0.25
    # The restarted instance answers once its addons are loaded.
    if "${FCITX[@]}" AvailableInputMethods 2>/dev/null | grep -q '"misstype"'; then
        break
    fi
done
if ! "${FCITX[@]}" AvailableInputMethods 2>/dev/null | grep -q '"misstype"'; then
    echo "fcitx5 restarted but does not list Misstype; check: fcitx5-diagnose" >&2
    exit 1
fi

# Add Misstype to the current group (kept in order, appended last) if missing.
python3 - <<'EOF'
import json, subprocess
call = ["busctl", "--user", "--json=short", "call", "org.fcitx.Fcitx5", "/controller",
        "org.fcitx.Fcitx.Controller1"]
group = json.loads(subprocess.check_output(call + ["CurrentInputMethodGroup"]))["data"][0]
layout, items = json.loads(subprocess.check_output(call + ["InputMethodGroupInfo", "s", group]))["data"]
if any(name == "misstype" for name, _ in items):
    print(f"Misstype is already in input-method group “{group}”.")
else:
    items.append(["misstype", ""])
    flat = [x for item in items for x in item]
    subprocess.check_call(call[:2] + call[3:] + ["SetInputMethodGroupInfo", "ssa(ss)", group, layout,
                          str(len(items))] + flat, stdout=subprocess.DEVNULL)
    subprocess.check_call(call[:2] + call[3:] + ["Save"], stdout=subprocess.DEVNULL)
    print(f"Added Misstype to input-method group “{group}”.")
EOF
echo "Installed Misstype $(git rev-parse --short HEAD). Switch to it with your fcitx5 hotkey and type su3cl3 → 你好."
