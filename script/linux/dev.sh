#!/usr/bin/env bash
# Run a command inside the Linux dev container (linux/Dockerfile) against a
# fresh copy of the working tree, so host build products never leak in:
#   script/linux/dev.sh 'swift test'
# The tree is mounted read-only; the copy lives at /w (the working dir).
# MISSTYPE_LINUX_BUILD_CACHE=1 opts into separate Linux-only compiler caches
# under .cache/linux-build. Default local runs still use clean build directories.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${MISSTYPE_LINUX_IMAGE:-misstype-linux-dev}"
# CI loads a Buildx image with cached layers before calling this wrapper.
# Local development still builds by default, so Dockerfile edits take effect.
if [ "${MISSTYPE_LINUX_PREBUILT:-0}" != "1" ]; then
  docker build -q -t "$IMAGE" -f "$ROOT/linux/Dockerfile" "$ROOT/linux" >/dev/null
fi
cache_args=()
if [ "${MISSTYPE_LINUX_BUILD_CACHE:-0}" = 1 ]; then
  cache="$ROOT/.cache/linux-build"
  mkdir -p "$cache/swift" "$cache/zig-local" "$cache/zig-global" "$cache/fcitx5"
  cache_args=(-v "$cache/swift":/w/.build
    -v "$cache/zig-local":/w/core-zig/.zig-cache
    -v "$cache/zig-global":/cache/zig-global
    -v "$cache/fcitx5":/w/build/fcitx5
    -e ZIG_GLOBAL_CACHE_DIR=/cache/zig-global)
fi
exec docker run --rm -v "$ROOT":/src:ro "${cache_args[@]}" "$IMAGE" \
  bash /src/script/linux/run_container.sh "$*"
