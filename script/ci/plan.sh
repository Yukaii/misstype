#!/usr/bin/env bash
# Decide which CI jobs an event needs, so the 10x-billed macOS runner and
# repeat work only run when they can find something new.
#
#   macos=true|false     the Swift/IMK job (Swift sources, C header, C ABI,
#                        build scripts, bundled resources changed)
#   verified=true|false  this push to main is a squash merge whose tree is
#                        identical to a PR head that already passed CI; only
#                        the main-only depth legs (full corpus) still run
#
# Env: EVENT (github.event_name), BASE (base sha; empty = run everything),
#      HEAD (sha under test), GH_REPO and GH_TOKEN for the merge lookup.
# Writes key=value lines to $GITHUB_OUTPUT, or stdout when run locally:
#   EVENT=pull_request BASE=origin/main HEAD=HEAD script/ci/plan.sh
set -euo pipefail

out=${GITHUB_OUTPUT:-/dev/stdout}
HEAD=${HEAD:-HEAD}

# Paths the macOS job compiles or bundles. Core decoder changes are covered on
# Linux (same Zig source); the release workflow still builds and tests macOS
# before anything ships, so a macOS-only compile break cannot reach users.
macos_paths='^(Sources/|tests/MisstypeMacKitTests/|tests/fixtures/lexicon/|Package\.(swift|resolved)$|Resources/|script/zig/|script/ci/|core-zig/build\.zig|core-zig/src/(capi|root)\.zig$|\.github/workflows/ci\.yml$)'

changed=
if [[ ${EVENT:-} == workflow_dispatch || -z ${BASE:-} || ${BASE} =~ ^0+$ ]]; then
  echo "plan: no usable base (${EVENT:-local}), running everything" >&2
  changed=ALL
else
  git cat-file -e "$BASE^{commit}" 2>/dev/null || git fetch --quiet --depth=1 origin "$BASE"
  changed=$(git diff --name-only "$BASE" "$HEAD")
fi

macos=false
if [[ $changed == ALL ]] || grep -Eq "$macos_paths" <<<"$changed"; then
  macos=true
fi

verified=false
if [[ ${EVENT:-} == push && -n ${GH_REPO:-} ]]; then
  sha=$(git rev-parse "$HEAD")
  pr_head=$(gh api "repos/$GH_REPO/commits/$sha/pulls" \
    --jq '[.[] | select(.merged_at)][0].head.sha // empty' 2>/dev/null || true)
  if [[ -n $pr_head ]]; then
    pr_tree=$(gh api "repos/$GH_REPO/git/commits/$pr_head" --jq .tree.sha 2>/dev/null || true)
    passed=$(gh api "repos/$GH_REPO/actions/workflows/ci.yml/runs?head_sha=$pr_head&event=pull_request&status=success" \
      --jq .total_count 2>/dev/null || echo 0)
    if [[ $pr_tree == "$(git rev-parse "$HEAD^{tree}")" && $passed -gt 0 ]]; then
      verified=true
      echo "plan: tree identical to PR head $pr_head, which passed CI" >&2
    else
      echo "plan: merged PR head $pr_head differs or has no green CI; full run" >&2
    fi
  fi
fi
[[ $verified == true ]] && macos=false

echo "plan: macos=$macos verified=$verified" >&2
printf 'macos=%s\nverified=%s\n' "$macos" "$verified" >>"$out"
