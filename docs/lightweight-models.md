# 輕量離線模型的量測與取捨

2026-10-14；全部是 Zig offline decoder，沒有 Transformer 或遠端 LLM。

現有 PR #83 同音詞 bigram PMI 重排表是目前最合理的預設：300k 詞對、
2.4 MB 原始檔，已能在 WASM 使用。它不是完整條件語言模型。本次新增
固定容量的比較框架，以及可明確選用的稀疏模型 WASM 載入能力；沒有替換
產品模型或預設權重。

## 先固定假設，再量測

* 同一批 dev + mixed-dev、兩個種子、3,616 個 real Session 案例，包含有聲調、
  無聲調、部分聲調與錯字、中文／英文混打。按鍵由固定 persona 產生，
  修正者使用 `punctuation-escape-v1`；首選、不可修復、補救按鍵均比較。
* 固定最高頻 50k／200k 條件模型，權重 0.5。保留 unigram 與特殊符號，
  刪掉的 direct mass 回退。這是計數剪枝，不是 entropy pruning。
* 另外固定 PR #83 相同 export 的 50k／100k PMI 表與無上下文下限，既有權重
  1.0；不再找權重。模型容量與假設先記錄在 development.md。
* 守門要求每個 track／persona 的不可修復數不增加，並保護每個 clean
  persona 的首選正確數；另外比較補救成本。只看總平均不足
  以採用。封存外部 200 句未使用；本輪 dev 結果不是泛化驗證。
* ReleaseFast native 計時：固定 24 句 × 8 persona × 2 seed = 384 案例、
  7,113 輸入鍵，單工作者。峰值 RSS 是 `/usr/bin/time` 的完整 typing batch，
  包含原生開發 CLI 預先載入的英文索引；不是只解一個短詞，也不是 IME 常駐量。

## Native 結果

「少／多補救」是相對現有 300k 表的案例數；direct exact 尚未操作候選。
MB 是十進位模型檔；記憶體是 MiB。時間為本機單次樣本，細微差異不能當勝負。

| 模型 | 原始 MB | 直接正確 /3616 | 不可修復 | 少／多補救 | mean / p95 ms | typing 峰值 MiB | 守門 |
|---|---:|---:|---:|---:|---:|---:|---|
| none | 0.00 | 2286 | 672 | 19 / 239 | 0.40 / 2.22 | 164.7 | 未通過 |
| pmi50k | 0.40 | 2424 | 666 | 25 / 95 | 0.40 / 2.23 | 165.2 | 未通過 |
| pmi100k | 0.80 | 2437 | 665 | 18 / 73 | 0.41 / 2.24 | 165.8 | 未通過 |
| default | 2.40 | 2479 | 665 | 0 / 0 | 0.41 / 2.24 | 167.2 | 通過 |
| 50k | 2.32 | 2384 | 667 | 123 / 234 | 1.02 / 5.13 | 169.1 | 未通過 |
| 200k | 4.12 | 2513 | 659 | 152 / 121 | 1.08 / 5.49 | 170.7 | 未通過 |
| full | 169.96 | 2644 | 647 | 251 / 56 | 1.43 / 7.06 | 479.4 | 通過 |

無表 → 現有表直接正確增加 193 句。0.4 MB／0.8 MB 表分別增加 138／151 句，
保留約 72%／78% 的這項增益，且反應時間近似；仍比現有表增加修正負擔，
例如中文 clean 組現有表為 264 句，0.4／0.8 MB 表為 262／260 句；
混打的無聲調／部分聲調 clean 組也退步。所以是低下載量的取捨選項，
不能宣稱替換預設後整體改善。

完整模型收益較大，卻需約 170 MB 檔、479 MiB typing 峰值與約 1.3 秒短詞
程序啟動（檔案快取已暖）。稀疏模型雖把模型降至 2.3／4.1 MB，兩者均未通過守門。
200k 的總首選提高仍掩蓋了部分 persona 的退步；50k 甚至低於現有表。
因此目前保留現有表，下一步的記憶體工作優先調查詞典索引與配置方式。

PMI 使用既有完整四 shard 詞對 cache；條件模型 pilot 只讀每 shard 前 10k
文件。比較的是各方案的部署取捨，不能把品質差異完全歸因於算法。
合成 persona 尚未以真人鍵序校準；句子數和同源資料也限制可信區間。
模型權重／容量反覆開發後，需要下一個固定候選才使用封存外部集一次驗證。

## 可攜與記憶體的界線

Node headless browser-WASI 重放相同 384 個 native 首選 trace；測量 `key +
state` 含 JS／JSON。WASM linear-memory 是已配置容量／高水位，不是瀏覽器
RSS；不能與 native 核心計時或 RSS 直接對比。尚未測真實手機瀏覽器。

中文詞庫初始化已配置約 93.2 MiB，載入英文索引後約 214.1 MiB。
現有表在中文模式打完約 111.1 MiB，含英文約 261.1 MiB。稀疏模型並沒有
解決這個底座成本。低階 wrapper 預設可不載英文；site loader 現在也能
明確指定 `englishUrl: null`，代價是沒有英文詞典功能，產品預設未改。

PMI 0.4／0.8 MB gzip 分別為約 0.25／0.50 MB，現有表為約 1.46 MB。
全部 14 組 WASM 配置的 native 首選 mismatch 均為 0（每組 384 案例）。
條件模型的中文 key+state 平均約 3.35／3.46 ms，現有表約 1.19 ms；
此區分也支持保留現有表。各容量／配置的原始數值見固定 JSON。

## 重跑

先依 [offline-word-model.md](offline-word-model.md) 及 `tools/word_lm.py --help` 建立 pinned
pilot，依 `tools/homophone_bigram.py --help` 建立既有 pinned pair cache；
資料與模型全部留在 cache，不提交生成的二進位。需要本地公開來源 cache、
shipping resources、ReleaseFast developer CLI、WASM 以及 Node dependencies。

```sh
python3 tools/prune_word_lm.py
# 固定容量的 PMI 導出，各跑一次 top-pairs 50000 / 100000：
python3 tools/homophone_bigram.py export --pairs "$HOME/.cache/misstype/hplt/pairs_toneless.tsv" --resources "$HOME/.cache/misstype/hplt/seglex" --out .cache/wordlm/pmi-tiny/pairs-50000.bin --top-pairs 50000 --rank sqrt --ambiguity toneless
python3 tools/homophone_bigram.py export --pairs "$HOME/.cache/misstype/hplt/pairs_toneless.tsv" --resources "$HOME/.cache/misstype/hplt/seglex" --out .cache/wordlm/pmi-tiny/pairs-100000.bin --top-pairs 100000 --rank sqrt --ambiguity toneless
# bin 必須是 ReleaseFast；預設 .cache/wordlm/bin/sparse-dev 可用 --bin 指定。
MISSTYPE_RESOURCES="$PWD/dist/MisstypeIME.app/Contents/Resources" python3 tools/small_model_eval.py
MISSTYPE_RESOURCES="$PWD/dist/MisstypeIME.app/Contents/Resources" python3 tools/small_model_eval.py --typing-memory-only
MISSTYPE_RESOURCES="$PWD/dist/MisstypeIME.app/Contents/Resources" python3 tools/small_model_eval.py --tiny-rerank --out .cache/wordlm/tiny-eval
MISSTYPE_RESOURCES="$PWD/dist/MisstypeIME.app/Contents/Resources" python3 tools/small_model_eval.py --tiny-rerank --out .cache/wordlm/tiny-eval --typing-memory-only
node tools/wasm_model_eval.mjs .cache/wordlm/small-eval
node tools/wasm_model_eval.mjs .cache/wordlm/tiny-eval --tiny-rerank
```

`report.json` 保留模型／資料／binary hash、環境、paired 結果與守門；逐案例
JSON 可重放。compact 固定結果提交於 `tools/eval/lightweight_v1.json`。
Linux C1–C15、IBus、核心與 C ABI 檢查均通過；Python 103、Zig 275、
WASM 與 package 測試通過，預設 decode／parity 及四組 replay goldens 未改。
