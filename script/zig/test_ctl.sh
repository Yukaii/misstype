#!/usr/bin/env bash
# misstypectl behavior suite against the Zig binary (any host).
set -euo pipefail
cd "$(dirname "$0")/../.."
zig=$(script/zig/bootstrap.sh)
(cd core-zig && "$zig" build)
python3 tests/capi/ctl_test.py core-zig/zig-out/bin/misstypectl
