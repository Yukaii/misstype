# 國家教育研究院《通用詞頻表》 — attribution

國家教育研究院，《通用詞頻表》（定稿 1141208），CC BY 4.0。
License: https://creativecommons.org/licenses/by/4.0/legalcode

Obtained as the `word<TAB>per_million` subset published by ChiaKey Lexicon
(`sources/naer-word-frequency/frequency.tsv`, pinned in `sources.json`),
whose notice records NAER's license confirmation (教研語譯字第 1150001412 號函).
Source notice: https://github.com/chiakich/ChiaKey-Lexicon/blob/889efe0da5e10f5eea5920027748e9dd1f58169a/sources/naer-word-frequency/LICENSE
Original dataset: https://coct.naer.edu.tw/page.jsp?ID=41

Changes made by Misstype: the per-million values are used only to rank
single characters that share a toneless Bopomofo base; they are not
redistributed. `script/prepare_lexicon.py` turns that ranking into
`toneless.tsv` (a permutation of Misstype's own McBopomofo-derived scores).
