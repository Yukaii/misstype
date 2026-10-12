#!/usr/bin/env bash
# Import the official Arch Linux ARM aarch64 rootfs as a Docker image (there is
# no Docker Hub image). Run on an aarch64 host.
# usage: import_alarm_rootfs.sh <image-name>
set -euo pipefail
image=${1:?usage: import_alarm_rootfs.sh <image-name>}
# The https endpoint of os.archlinuxarm.org serves a mismatched certificate;
# integrity comes from the pinned Arch Linux ARM Build System signing key.
url=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
key=68B3537F39A313B3E574D06777193F152BDBE6A6
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fL --retry 3 -o "$work/rootfs.tar.gz" "$url"
curl -fL --retry 3 -o "$work/rootfs.tar.gz.sig" "$url.sig"
export GNUPGHOME=$work/gnupg
mkdir -m700 "$GNUPGHOME"
gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key"
gpg --batch --status-fd 1 --verify "$work/rootfs.tar.gz.sig" "$work/rootfs.tar.gz" \
    | grep -E "^\[GNUPG:\] VALIDSIG .*$key"
# A bare rootfs import sets no PATH, so containers could not find bash.
docker import --change 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/bin' - "$image" < "$work/rootfs.tar.gz"
# Fail here, with a clear message, rather than at the first `docker run … bash`.
docker run --rm "$image" bash -c 'echo "$(uname -m) rootfs ready"'
