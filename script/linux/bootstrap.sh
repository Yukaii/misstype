#!/usr/bin/env bash
# Bare-metal provision for the Linux test layers (no Docker).
#
# Installs native build dependencies and the pinned Zig toolchain by default.
# MISSTYPE_CORE=swift also provisions the Swift reference toolchain.
# Usage: script/linux/bootstrap.sh && script/linux/test_all.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

SWIFT_TAR="swift-6.0-RELEASE-ubuntu24.04.tar.gz"
SWIFT_URL="https://download.swift.org/swift-6.0-release/ubuntu2404/swift-6.0-release/${SWIFT_TAR}"
TOOLCHAIN_ROOT="${SWIFT_TOOLCHAIN_ROOT:-$HOME/swift-toolchain}"

# Same native build packages as the dev image. Curl headers are needed only
# by the optional Swift oracle (FoundationNetworking).
APT_PKGS="cmake make g++ pkg-config extra-cmake-modules gettext python3 curl xz-utils \
    fcitx5 libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev \
    fcitx5-modules-dev libgtk-4-dev"
case "${MISSTYPE_CORE:-zig}" in
    zig) ;;
    swift) APT_PKGS="$APT_PKGS libcurl4-openssl-dev" ;;
    *) echo "bootstrap: MISSTYPE_CORE must be zig or swift" >&2; exit 1 ;;
esac

# Another apt user (unattended-upgrades, a provisioner) may hold the lock.
for i in $(seq 1 30); do
    if ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then break; fi
    echo "bootstrap: waiting for apt lock (${i}/30)..."
    sleep 10
done

sudo apt-get update
# shellcheck disable=SC2086
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $APT_PKGS

if [ "${MISSTYPE_CORE:-zig}" = swift ]; then
    mkdir -p "$TOOLCHAIN_ROOT"
    if [ ! -x "$TOOLCHAIN_ROOT/swift-6.0-RELEASE-ubuntu24.04/usr/bin/swift" ]; then
        if [ ! -f "$TOOLCHAIN_ROOT/$SWIFT_TAR" ]; then
            echo "bootstrap: downloading Swift 6.0 toolchain (~800MB)..."
            curl -fL --retry 3 -o "$TOOLCHAIN_ROOT/$SWIFT_TAR" "$SWIFT_URL"
        fi
        tar -xzf "$TOOLCHAIN_ROOT/$SWIFT_TAR" -C "$TOOLCHAIN_ROOT"
    fi
    "$TOOLCHAIN_ROOT/swift-6.0-RELEASE-ubuntu24.04/usr/bin/swift" --version

else
    zig=$(script/zig/bootstrap.sh)
    "$zig" version
fi

echo "bootstrap: done. Next:"
if [ "${MISSTYPE_CORE:-zig}" = swift ]; then
    echo "  export PATH=\"$TOOLCHAIN_ROOT/swift-6.0-RELEASE-ubuntu24.04/usr/bin:\$PATH\""
    echo "  MISSTYPE_CORE=swift script/linux/test_all.sh"
else
    echo "  script/linux/test_all.sh"
fi
