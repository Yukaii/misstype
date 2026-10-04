# FrequencyWords (English 50k) — attribution

Hermit Dave, *FrequencyWords*, https://github.com/hermitdave/FrequencyWords
(`content/2018/en/en_50k.txt`, pinned in `sources.json`).
Code: MIT License. Content: **CC BY-SA 4.0**
(https://creativecommons.org/licenses/by-sa/4.0/legalcode), derived from
OpenSubtitles 2018 (http://opus.nlpl.eu/OpenSubtitles2018.php).

Used only to recognize English words typed without a mode switch and to rank
them (`word<SPACE>count` -> natural-log probability). `script/prepare_lexicon.py`
writes `.cache/frequencywords/english.tsv`; nothing is committed.

ShareAlike note: the derived `english.tsv` is an adaptation of CC BY-SA
content. It stays in the (uncommitted) cache during development. If an
installer or app bundle ever ships it, that file must be offered under
CC BY-SA 4.0 with this attribution, or the source swapped for a permissively
licensed list (SCOWL is the candidate). Decision recorded 2026-10-04.
