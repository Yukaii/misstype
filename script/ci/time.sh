#!/usr/bin/env bash
# Time a phase on stderr so decoder/replay stdout stays byte-comparable.
# Usage: script/ci/time.sh <label> <command> [args...]
set -euo pipefail
label=$1
shift
TIMEFORMAT="timing: $label wall=%3Rs user=%3Us sys=%3Ss"
time "$@"
