#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
zig=$(script/zig/bootstrap.sh)
(cd core-zig && "$zig" build)
script/linux/dev.sh 'MISSTYPE_CORE=swift script/linux/build_capi.sh >&2; mkdir -p build/zig-capi; cp /src/core-zig/zig-out/lib/libMisstypeCAPI.so build/zig-capi/; python3 tests/capi/persistence.py "$(cat build/capi/libdir)/libMisstypeCAPI.so" build/zig-capi/libMisstypeCAPI.so'
