# Taiwan government open data — attribution for `place_names.tsv`

`Resources/place_names.tsv` lists Taiwan place names that the McBopomofo
lexicon lacks, with Bopomofo readings and a fixed score. It is built by
`tools/place_names.py` from two Ministry of the Interior (內政部) open
datasets, pinned with checksums in `sources.json`:

- 全國路名資料 (national road names), year 115, data.gov.tw dataset 35321,
  provided by the Department of Household Registration (內政部戶政司):
  https://data.gov.tw/dataset/35321
- 代碼服務－村里清單 (village code list), data.gov.tw dataset 102017, served by
  the National Land Surveying and Mapping Center (內政部國土測繪中心):
  https://data.gov.tw/dataset/102017

## Licence and required notice

Both datasets are released under the Open Government Data License, version
1.0 (政府資料開放授權條款－第1版), https://data.gov.tw/license , which permits
use, reproduction, adaptation and redistribution with attribution, and is
compatible with CC BY 4.0. The notice the licence asks users to display:

> 此開放資料依政府資料開放授權條款 (Open Government Data License) 進行公眾釋出，
> 使用者於遵守本條款各項規定之前提下，得利用之。
> 政府資料開放授權條款：https://data.gov.tw/license
>
> This open data is released to the public under the Open Government Data
> License; users may use it subject to the terms of that licence.

Data provider: 內政部 (Ministry of the Interior, Taiwan).

## What Misstype changed

Misstype keeps only the names (no codes, coordinates or other fields),
removes names already in its dictionary, adds the stem of a road or village
name when it is two or more characters (裕農路 → 裕農, 翠屏里 → 翠屏), and
adds a Bopomofo reading built from each character's best-scored dictionary
reading. Readings of characters with several pronunciations have not been
reviewed and may be wrong. The file is offered under the same Open
Government Data License with the attribution above; Misstype's MIT licence
covers its code only.

The names load only together with `word_model.bin`, which was trained with
them; without it, deleting `place_names.tsv` changes nothing.
