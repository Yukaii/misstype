#!/usr/bin/env bash
# Bare-metal provision for the Linux test layers (no Docker).
#
# Installs the Swift 6.0 toolchain and the native packages that
# linux/Dockerfile installs inside the container, so the Linux checks can
# run directly on the host. Idempotent: safe to re-run after the machine
# is reprovisioned (system packages do not survive that; the toolchain
# tarball is cached under $SWIFT_TOOLCHAIN_ROOT).
#
# Usage: script/linux/bootstrap.sh
# Then:  export PATH="$HOME/swift-toolchain/swift-6.0-RELEASE-ubuntu24.04/usr/bin:$PATH"
#        script/linux/test_all.sh
set -euo pipefail

SWIFT_TAR="swift-6.0-RELEASE-ubuntu24.04.tar.gz"
SWIFT_URL="https://download.swift.org/swift-6.0-release/ubuntu2404/swift-6.0-release/${SWIFT_TAR}"
TOOLCHAIN_ROOT="${SWIFT_TOOLCHAIN_ROOT:-$HOME/swift-toolchain}"

# Same set as linux/Dockerfile, plus libcurl4-openssl-dev: the swift:6.0
# image already ships curl headers, bare Ubuntu 24.04 does not, and the
# release .so links libcurl via FoundationNetworking.
APT_PKGS="cmake make g++ pkg-config extra-cmake-modules gettext python3 \
    fcitx5 libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev \
    fcitx5-modules-dev libcurl4-openssl-dev"

# Another apt user (unattended-upgrades, a provisioner) may hold the lock.
for i in $(seq 1 30); do
    if ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then break; fi
    echo "bootstrap: waiting for apt lock (${i}/30)..."
    sleep 10
done

sudo apt-get update
# shellcheck disable=SC2086
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $APT_PKGS

mkdir -p "$TOOLCHAIN_ROOT"
if [ ! -x "$TOOLCHAIN_ROOT/swift-6.0-RELEASE-ubuntu24.04/usr/bin/swift" ]; then
    if [ ! -f "$TOOLCHAIN_ROOT/$SWIFT_TAR" ]; then
        echo "bootstrap: downloading Swift 6.0 toolchain (~800MB)..."
        curl -fL --retry 3 -o "$TOOLCHAIN_ROOT/$SWIFT_TAR" "$SWIFT_URL"
    fi
    tar -xzf "$TOOLCHAIN_ROOT/$SWIFT_TAR" -C "$TOOLCHAIN_ROOT"
fi
"$TOOLCHAIN_ROOT/swift-6.0-RELEASE-ubuntu24.04/usr/bin/swift" --version

chmod +x script/linux/*.sh script/*.sh 2>/dev/null || true

echo
echo "bootstrap: done. Next:"
echo "  export PATH=\"$TOOLCHAIN_ROOT/swift-6.0-RELEASE-ubuntu24.04/usr/bin:\$PATH\""
echo "  script/linux/test_all.sh"
