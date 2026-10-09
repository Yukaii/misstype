#!/usr/bin/env bash
# User-file persistence and resource-boundary checks through the C ABI,
# against the Zig library and the files the retired Swift implementation
# wrote (tests/capi/golden).
set -euo pipefail
cd "$(dirname "$0")/../.."
zig=$(script/zig/bootstrap.sh)
(cd core-zig && "$zig" build)
script/linux/dev.sh 'mkdir -p build/zig-capi; cp /src/core-zig/zig-out/lib/libMisstypeCAPI.so build/zig-capi/; python3 tests/capi/persistence.py build/zig-capi/libMisstypeCAPI.so'
