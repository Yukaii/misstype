#!/usr/bin/env bash
# Run the focused checks for the layers a change touches, using the same path
# rules as CI (script/ci/layers.sh). Run it before calling a change done.
#
#   script/check.sh             changes vs. the merge base with origin/main,
#                               including uncommitted and untracked files
#   script/check.sh --all       every local layer
#   script/check.sh --base REF  compare against REF instead
#   script/check.sh --deep      also the golden gates and typing evaluation
#                               when the core changed (minutes; CI runs them)
#   script/check.sh --linux     also the fcitx5/IBus suites in Docker
#   script/check.sh --list      print the plan without running anything
#
# Every selected check runs even after a failure; the summary lists each one
# and the exit status is non-zero if any failed. Layers whose tools are not
# available here (Swift off macOS, Docker) are reported as skipped, never as
# passed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
root=$PWD
# shellcheck source=script/ci/layers.sh
source script/ci/layers.sh

base="" all=false deep=false linux=false list=false
while (($#)); do
  case $1 in
    --all) all=true ;;
    --base) base=$2; shift ;;
    --deep) deep=true ;;
    --linux) linux=true ;;
    --list) list=true ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "check: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

if $all; then
  changed=ALL
else
  base=${base:-$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)}
  changed=$(changed_files "$base")
  if [[ -z $changed ]]; then
    echo "check: nothing changed since ${base:0:12}; use --all to check everything"
    exit 0
  fi
fi

# shellcheck disable=SC2329  # called from the eval'd steps below
zig() { "$("$root/script/zig/bootstrap.sh")" "$@"; }
# npm_ready: install when node_modules is missing or older than the lockfile
# (a stale tree fails with ERR_MODULE_NOT_FOUND that looks like a test bug).
# shellcheck disable=SC2329
npm_ready() {
  [[ node_modules/.package-lock.json -nt package-lock.json ]] || npm ci --no-audit --no-fund "$@"
}
plan=() results=() failed=0

# step NAME COMMAND...: queue a check (run below, or just listed with --list).
step() { plan+=("$1"$'\t'"${*:2}"); }
skip() { results+=("skip  $1 ($2)"); }

if touches zig "$changed"; then
  step "zig fmt" "cd core-zig && zig fmt --check build.zig src"
  step "zig build test" "cd core-zig && zig build test"
  if $deep; then
    step "golden: exact decoder" "core-zig/bench/compare.sh"
    step "golden: candidates/touch/unicode" "core-zig/bench/parity.sh"
    step "golden: session replay" "core-zig/bench/replay.sh"
    step "typing eval vs baseline" "(cd core-zig && zig build -Doptimize=ReleaseFast) && python3 tools/typing_eval.py --baseline tools/baseline/typing_eval.json"
  fi
fi
if touches capi "$changed"; then
  step "C ABI: misstypectl" "(cd core-zig && zig build) && python3 tests/capi/ctl_test.py core-zig/zig-out/bin/misstypectl"
fi
if touches wasm "$changed"; then
  step "wasm build + API suite" "(cd core-zig && zig build wasm) && mkdir -p site/public && cp core-zig/zig-out/wasm/misstype.wasm site/public/ && node tests/wasm_test.mjs"
  step "npm misstype-wasm" "cd packages/misstype-wasm && npm_ready --ignore-scripts && npm test"
fi
if touches macos "$changed"; then
  if [[ $(uname) == Darwin ]]; then
    step "macOS: Swift build + tests" "MISSTYPE_MACOS_ARCH=native script/zig/build_macos.sh && swift test"
  else
    skip "macOS: Swift build + tests" "needs macOS; CI runs it"
  fi
fi
if touches l10n "$changed"; then
  step "localizations" "python3 tools/check_localizations.py"
fi
if touches site "$changed"; then
  step "site tests" "cd site && npm_ready && npm test"
fi
if touches obsidian "$changed"; then
  step "obsidian plugin tests" "cd packages/obsidian-misstype && npm_ready && npm run build && npm test"
fi
if touches python "$changed"; then
  step "python tests" "PYTHONPATH=src python3 -m unittest discover -s tests"
fi
if touches linux "$changed"; then
  if $linux; then
    step "linux: fcitx5 + IBus (Docker)" "script/linux/dev.sh 'bash script/linux/test_all.sh'"
  else
    skip "linux: fcitx5 + IBus" "pass --linux to run in Docker; CI runs it"
  fi
fi
if touches docs "$changed"; then
  step "doc paths" "python3 tools/check_doc_paths.py"
fi
if touches workflows "$changed"; then
  if command -v actionlint >/dev/null; then
    step "actionlint" "actionlint"
  else
    skip "actionlint" "not installed"
  fi
fi

if $list; then
  [[ $changed == ALL ]] || printf 'changed:\n%s\n\n' "${changed//$'\n'/$'\n'  }"
  for p in "${plan[@]}"; do printf 'run   %s\n      %s\n' "${p%%$'\t'*}" "${p#*$'\t'}"; done
  for r in "${results[@]}"; do echo "$r"; done
  exit 0
fi

export -f zig npm_ready
for p in "${plan[@]}"; do
  name=${p%%$'\t'*} cmd=${p#*$'\t'}
  echo "── $name"
  start=$SECONDS
  if (eval "$cmd"); then
    results+=("ok    $name ($((SECONDS - start))s)")
  else
    results+=("FAIL  $name ($((SECONDS - start))s): $cmd")
    failed=1
  fi
done

echo
echo "── check summary"
((${#results[@]})) || echo "no layer matched the changed files"
for r in "${results[@]}"; do echo "$r"; done
exit $failed
