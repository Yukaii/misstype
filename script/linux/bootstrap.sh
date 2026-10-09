#!/usr/bin/env bash
# Bare-metal provision for the Linux test layers (no Docker).
#
# Installs native build dependencies and the pinned Zig toolchain.
# Usage: script/linux/bootstrap.sh && script/linux/test_all.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

# Same native build packages as the dev image.
APT_PKGS="cmake make g++ pkg-config extra-cmake-modules gettext python3 curl xz-utils \
    fcitx5 libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev \
    fcitx5-modules-dev libgtk-4-dev"
# Another apt user (unattended-upgrades, a provisioner) may hold the lock.
for i in $(seq 1 30); do
    if ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then break; fi
    echo "bootstrap: waiting for apt lock (${i}/30)..."
    sleep 10
done

sudo apt-get update
# shellcheck disable=SC2086
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $APT_PKGS

zig=$(script/zig/bootstrap.sh)
"$zig" version

echo "bootstrap: done. Next:"
echo "  script/linux/test_all.sh"
