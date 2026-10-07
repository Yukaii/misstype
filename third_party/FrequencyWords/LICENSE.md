# FrequencyWords (English 50k) — attribution

Hermit Dave, *FrequencyWords*, https://github.com/hermitdave/FrequencyWords
(`content/2018/en/en_50k.txt`, pinned in `sources.json`).
Code: MIT License. Content: **CC BY-SA 4.0**
(https://creativecommons.org/licenses/by-sa/4.0/legalcode), derived from
OpenSubtitles 2018 (http://opus.nlpl.eu/OpenSubtitles2018.php).

Changes made by Misstype: retain lowercase ASCII alphabetic words, normalize
their counts over the retained entries, and write six-decimal natural-log
probabilities (`word<TAB>ln p`). `script/prepare_lexicon.py` writes
`.cache/frequencywords/english.tsv`; the generated data is not committed.

The derived `english.tsv` is offered under **CC BY-SA 4.0** wherever it is
distributed: the macOS app/installer, Linux data directory, and website's
downloadable demo assets. Retain this attribution, the license link, and the
change description when sharing it. This data license is separate from
Misstype's MIT-licensed code.
