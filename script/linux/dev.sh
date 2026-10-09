#!/usr/bin/env bash
# Run a command inside the Linux dev container (linux/Dockerfile) against a
# fresh copy of the working tree, so host build products never leak in:
#   script/linux/dev.sh 'swift test'
# The tree is mounted read-only; the copy lives at /w (the working dir).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${MISSTYPE_LINUX_IMAGE:-misstype-linux-dev}"
# CI loads a Buildx image with cached layers before calling this wrapper.
# Local development still builds by default, so Dockerfile edits take effect.
if [ "${MISSTYPE_LINUX_PREBUILT:-0}" != "1" ]; then
  docker build -q -t "$IMAGE" -f "$ROOT/linux/Dockerfile" "$ROOT/linux" >/dev/null
fi
exec docker run --rm -v "$ROOT":/src:ro "$IMAGE" bash -euo pipefail -c \
  'mkdir -p /w && tar -C /src --exclude=./.build --exclude=./dist --exclude=./build --exclude=./.cache/zig --exclude=./core-zig/.zig-cache --exclude=./core-zig/zig-out -cf - . | tar -C /w -xf - && cd /w && if [ -x /src/.cache/zig/0.17.0/zig ] && [ "$(head -c 4 /src/.cache/zig/0.17.0/zig | od -An -t x1 | tr -d " \\n")" = 7f454c46 ]; then export MISSTYPE_ZIG=/src/.cache/zig/0.17.0/zig; fi && '"$*"
