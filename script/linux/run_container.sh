#!/usr/bin/env bash
# Internal entrypoint for dev.sh, at the stable /w path used by build caches.
set -euo pipefail
mkdir -p /w
/src/script/ci/time.sh container-copy bash -euo pipefail -c '
    tar -C /src --exclude=./.build --exclude=./dist --exclude=./build \
        --exclude=./.cache/linux-build --exclude=./.cache/zig \
        --exclude=./core-zig/.zig-cache --exclude=./core-zig/zig-out -cf - . \
        | tar -C /w -xf -
'
cd /w
if [ -x /src/.cache/zig/0.17.0/zig ] && \
    [ "$(head -c 4 /src/.cache/zig/0.17.0/zig | od -An -t x1 | tr -d ' \n')" = 7f454c46 ]; then
    export MISSTYPE_ZIG=/src/.cache/zig/0.17.0/zig
fi
status=0
script/ci/time.sh container-command bash -euo pipefail -c "$1" || status=$?
# Docker runs as root, while the Actions runner saves the bind-mounted cache
# as its own user. Make compiler artifacts readable before the container exits.
for cache_dir in /w/.build /w/core-zig/.zig-cache /cache/zig-global /w/build/fcitx5; do
    [ -d "$cache_dir" ] && chmod -R a+rX "$cache_dir" || true
done
exit "$status"
