#!/usr/bin/env bash
# Bare-metal Linux test layers (no Docker): MisstypeCore, the C ABI, and the
# fcitx5 addon headless conformance tests. This is what CI's fcitx5-linux
# job runs inside the container (script/linux/dev.sh), minus Docker.
#
# Provision first: script/linux/bootstrap.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v swift >/dev/null 2>&1 || {
    echo "test_all: swift not in PATH; run script/linux/bootstrap.sh first" >&2
    exit 1
}

# Lexicon cache: script/prepare_lexicon.py fetches the pinned sources with
# urllib, which can time out on flaky networks while curl succeeds. If the
# first attempt fails, pre-seed the cache with curl and let the script
# verify checksums on retry. The cache (.cache/) is never committed.
if [ ! -f .cache/mcbopomofo/lexicon.tsv ] || [ ! -f .cache/frequencywords/english.tsv ]; then
    if ! python3 script/prepare_lexicon.py; then
        echo "test_all: urllib fetch failed; pre-seeding .cache with curl"
        python3 - <<'EOF'
import hashlib, json, subprocess
from pathlib import Path
for manifest_path in sorted(Path("third_party").glob("*/sources.json")):
    manifest = json.loads(manifest_path.read_text())
    repo = manifest["repository"].removeprefix("https://github.com/")
    # prepare_lexicon.py reads lowercase cache dirs (.cache/mcbopomofo, ...).
    cache = Path(".cache") / manifest_path.parent.name.lower()
    cache.mkdir(parents=True, exist_ok=True)
    for path, digest in manifest["files"].items():
        target = cache / Path(path).name
        if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == digest:
            continue
        url = f"https://raw.githubusercontent.com/{repo}/{manifest['commit']}/{path}"
        subprocess.run(["curl", "-fL", "--retry", "3", "-o", str(target), url], check=True)
        assert hashlib.sha256(target.read_bytes()).hexdigest() == digest, path
        print("seeded", target)
EOF
        python3 script/prepare_lexicon.py
    fi
fi

swift test
script/linux/test_capi.sh
script/linux/test_fcitx5.sh
echo "ALL LINUX TESTS OK"
