#!/usr/bin/env bash
# Run a command inside the Linux dev container (linux/Dockerfile) against a
# fresh copy of the working tree, so host build products never leak in:
#   script/linux/dev.sh 'swift test'
# The tree is mounted read-only; the copy lives at /w (the working dir).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${MISTYPE_LINUX_IMAGE:-mistype-linux-dev}"
docker build -q -t "$IMAGE" -f "$ROOT/linux/Dockerfile" "$ROOT/linux" >/dev/null
exec docker run --rm -v "$ROOT":/src:ro "$IMAGE" bash -euo pipefail -c \
  'mkdir -p /w && tar -C /src --exclude=./.build --exclude=./dist --exclude=./build -cf - . | tar -C /w -xf - && cd /w && '"$*"
