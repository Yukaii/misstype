"""Reserve external text before decoder experiments; never runs a decoder.

Reads the existing local Common Voice 25 zh-TW public cache. Excludes a
conservative legacy prefix and the repository's synthetic evaluation text,
then takes a fixed hash sample. The generated TSV stays in .cache; commit
the source/lexicon hashes and selected IDs in the manifest, not results.

This holds out text from our parameter selection, not from HPLT training.
Pronunciations are derived from the pinned dictionary, not human tap logs.
"""

import argparse
import hashlib
import json
from pathlib import Path

import cursor_replay as cursor
import typing_eval as typing

SALT = "misstype-external-zh-tw-v1"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sample(rows: list[tuple[str, str, str]], excluded: set[str], legacy: int,
           count: int) -> list[tuple[str, str, str]]:
    # Deduplicate text before reserving; two IDs must never let one sentence
    # slip out of the legacy exclusion and into the new test set.
    unique = {}
    for source_id, text, reading in sorted(rows):
        unique.setdefault(text, (source_id, text, reading))
    ordered = sorted(unique.values())
    pool = [row for row in ordered[legacy:] if row[1] not in excluded]
    pool.sort(key=lambda row: digest((SALT + "\0" + row[1]).encode()))
    if len(pool) < count:
        raise ValueError(f"only {len(pool)} unseen eligible sentences for a sample of {count}")
    return pool[:count]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path,
                        default=Path.home() / ".cache/misstype/cv/validated_sentences.tsv")
    parser.add_argument("--lexicon", type=Path, default=cursor.LEXICON)
    parser.add_argument("--legacy-prefix", type=int, default=2000)
    parser.add_argument("--count", type=int, default=200)
    parser.add_argument("--out", type=Path, default=typing.ROOT / ".cache/eval-reserve/external-v1.tsv")
    parser.add_argument("--manifest", type=Path,
                        default=typing.ROOT / "tools/eval/external_v1.json")
    args = parser.parse_args()
    if args.count < 1 or args.legacy_prefix < 0:
        parser.error("count must be positive and legacy-prefix nonnegative")
    source = args.source.read_bytes()
    reverse = cursor.load_reverse_lexicon(args.lexicon)
    rows, unreadable = [], 0
    for line in source.decode().splitlines()[1:]:
        fields = line.split("\t")
        if len(fields) < 2:
            continue
        source_id, text = fields[0], fields[1].strip()
        if not 4 <= len(text) <= 16 or not all("\u4e00" <= c <= "\u9fff" for c in text):
            continue
        try:
            reading = cursor.readings_for(text, reverse)
        except ValueError:
            unreadable += 1
            continue
        rows.append((source_id, text, reading))
    excluded = {row[2] for row in typing.load_corpus()}
    excluded.update(text for text, _ in cursor.SEED)
    excluded.update(cursor.DEV_EXTRA)
    excluded.update(cursor.HOLDOUT)
    chosen = sample(rows, excluded, args.legacy_prefix, args.count)
    output = "# Reserved external text; offline pronunciation/typing simulation, not real key logs.\n"
    output += "".join(f"holdout\texternal\t{text}\t{reading}\n" for _, text, reading in chosen)
    manifest = {
        "version": 1, "dataset": "Common Voice 25 zh-TW validated sentences (existing public cache, CC0)",
        "source_sha256": digest(source), "lexicon_sha256": digest(args.lexicon.read_bytes()),
        "synthetic_corpus_sha256": digest(typing.CORPUS.read_bytes()),
        "selection": {"salt": SALT, "length": [4, 16], "pure_han": True,
                      "legacy_unique_readable_prefix": args.legacy_prefix, "count": args.count},
        "unreadable_source_rows": unreadable,
        "output_sha256": digest(output.encode()),
        "training_contamination_checked": False, "human_pronunciations_checked": False,
        "sentences": [{"id": source_id, "text_sha256": digest(text.encode()),
                       "reading_sha256": digest(reading.encode())} for source_id, text, reading in chosen],
    }
    if args.manifest.exists():
        frozen = json.loads(args.manifest.read_text())
        if frozen != manifest:
            raise ValueError("frozen manifest differs; preserve it and reserve a new named version")
    else:
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        args.manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(output)
    print(f"Reserved {len(chosen)} independent sentences without running a decoder; "
          f"manifest {args.manifest}; corpus {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
