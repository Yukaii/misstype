#!/usr/bin/env bash
# misstypectl gates: the behavior suite against the Zig binary (any host),
# then, while the Swift reference still exists, the Swift/Zig diff on Linux.
set -euo pipefail
cd "$(dirname "$0")/../.."
zig=$(script/zig/bootstrap.sh)
(cd core-zig && "$zig" build)
python3 tests/capi/ctl_test.py core-zig/zig-out/bin/misstypectl
script/linux/dev.sh 'MISSTYPE_CORE=swift script/linux/build_capi.sh >&2; mkdir -p build/zig-capi; cp /src/core-zig/zig-out/bin/misstypectl build/zig-capi/; python3 tests/capi/ctl_parity.py "$(cat build/capi/libdir)/misstypectl" build/zig-capi/misstypectl'
