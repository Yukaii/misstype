# shellcheck shell=bash
# Which layer a changed path belongs to. Sourced by script/ci/plan.sh (what CI
# runs) and script/check.sh (what an agent or human runs before calling a
# change done), so both agree on what a change touches. Extended regexes over
# repository-relative paths.

# shellcheck disable=SC2034  # read by the sourcing scripts

# Zig core: decoding, session, editing rules.
LAYER_zig='^(core-zig/|third_party/utf8proc/|script/zig/bootstrap\.sh$)'
# C ABI and misstypectl (header, exports, persistence and CLI fixtures).
LAYER_capi='^(Sources/CMisstype/include/|core-zig/src/(capi|ctl|root)\.zig$|tests/capi/)'
# Everything the macOS IME job compiles or bundles.
LAYER_macos='^(Sources/|tests/MisstypeMacKitTests/|tests/fixtures/lexicon/|Package\.(swift|resolved)$|Resources/|script/zig/|script/ci/|core-zig/build\.zig|core-zig/src/(capi|root)\.zig$|\.github/workflows/ci\.yml$)'
# User-visible macOS strings.
LAYER_l10n='^(Sources/MisstypeIME/|Sources/MisstypeInstaller/|Resources/.*\.lproj/|tools/check_localizations\.py$)'
# wasm32-wasi build and its JavaScript consumers.
LAYER_wasm='^(core-zig/src/|core-zig/build\.zig|packages/misstype-wasm/|tests/wasm_test\.mjs$)'
LAYER_site='^(site/|tests/editor_[a-z_]+\.mjs$)'
LAYER_obsidian='^packages/obsidian-misstype/'
# Python tools and their tests.
LAYER_python='^(src/|tools/.*\.py$|tests/test_[a-z_]+\.py$|pyproject\.toml$)'
# fcitx5 / IBus adapters (Docker; slow, opt-in locally).
LAYER_linux='^(linux/|script/linux/|core-zig/src/(capi|root)\.zig$|Sources/CMisstype/include/)'
LAYER_docs='\.md$'
LAYER_workflows='^\.github/workflows/'

# changed_files BASE [HEAD]: paths changed between BASE and HEAD; without HEAD,
# between BASE and the working tree including untracked files.
changed_files() {
  if [[ -n ${2:-} ]]; then
    git diff --name-only "$1" "$2"
  else
    { git diff --name-only "$1"; git ls-files --others --exclude-standard; } | sort -u
  fi
}

# touches LAYER "$changed": true when any changed path matches the layer.
touches() {
  local var="LAYER_$1"
  [[ $2 == ALL ]] || grep -Eq "${!var}" <<<"$2"
}
