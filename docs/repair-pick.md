# 修復詞選字的鎖定（2026-10-14）

本頁保存位置鎖定修正的結果。後續切分反例被確認為模擬修正者的標點選單
漏選，最新重放與結果見 [punctuation-correction.md](punctuation-correction.md)。

游標列表列出了修復詞，但選字後仍顯示原文字：Session 把選字鎖定存成
原始輸入的 `run#offset@readings`，解碼卻只以修復後的字典讀音查鎖定。
漏打 `/` 的 `ej tk ` 選「公車」就是例子：鎖定讀音是 ㄍㄨㄔㄜ，字典路徑
是 ㄍㄨㄥㄔㄜ；原先沒有得到選字加分，刷新又回到「估車」。

解碼現在也用原始輸入的讀音查位置鎖定，並允許明確選過的詞越過每個
reading 的 entry cap。既有字典讀音匹配保持相容。修復成本照算，原始
按鍵、聲調、位置鎖定格式與平台 ABI 都不變；沒有放寬未選字的修復搜尋。

## 重現與證據

`core_test.zig` 用三條詞庫項重現：估 -1、車 -2、公車 -4。
`ej tk ` 初始顯示「估車」，選「公車」後得到一次修復的「公車」，原始
第一音節仍是 `ej`。`caret_test.zig` 經真正的 Session 游標選字、刷新及
Return 驗證同樣結果。新增測試先在舊實作失敗，再以修正通過。

完整真實詞庫反例（純合成）可用：

```sh
MISSTYPE_WORD_LM="$PWD/.cache/wordlm/pilot.bin" MISSTYPE_WORD_LM_WEIGHT=0.5 \
  core-zig/zig-out/bin/misstype-dev \
  --session-trace 'ej tk c96ao6x96←←←←←↓a' --show --show-candidates
```

`--show-candidates` 是新增的開發 CLI 診斷：每鍵輸出 `candidate`、步數、
零起算列索引與文字。普通 trace／batch 輸出不變。列表可在第一音節找到
「公車」；選下後文字改成「公車還沒來」。`typing_eval.py` 的正常補救
流程也能送出正確句子，原先同一流程送出「估車還沒來」。

## 成對評估

正式預設的 7,200 個模擬案例，對原 baseline 是 FIXED 11／BROKEN 0，
首選文字不變。FIXED 以補救選字成本衡量，不可修復句子的成本為無限大；
它不是聲稱每個失敗句的按鍵數都變少。部分仍失敗的噪聲案例在選字有效
後會嘗試更多補救按鍵。已更新 typing baseline，沒有使用 LLM。

同一詞模型、固定權重 0.5、同序分批的 dev 3,616 案例：

| 指標 | 修正後正式預設 | 修正後模型 0.5 |
| --- | ---: | ---: |
| 首選正確句子 | 2,479 | 2,644 |
| 不可修復句子 | 665 | 648 |
| 可修復句子的選字次數 | 526 | 327 |
| 減少／增加選字案例 | 基準 | 251／57 |
| 部分聲調錯字組不可修復 | 42 | 43 |

新模型仍未通過每個 persona 的可修復率守門；外部 200 句保持未使用。
固定 protocol、雜湊與分組結果見
[word_lm_pin_fix_v1.json](../tools/eval/word_lm_pin_fix_v1.json)。重跑：

```sh
python3 tools/eval_word_lm.py --repair-check \
  --bin .cache/wordlm/bin/pin-fixed-dev --out .cache/wordlm/pin-fix-dev
```

`--repair-check` 只比較正式預設與已固定的 0.5，沒有重選模型或搜尋新權重。
其他反例仍保留在 [word-model.md](../tests/fixtures/word-model.md)；其中
`2jo41jfu3，jit42l4xk7。` 的「對不起，我遲到了。」在模型下變成
「對不起，握到了。」這次位置鎖定修正未解決它；後續已確認整句候選存在，只是標點選單
遮住它，並以模擬修正者的 Esc 操作補救。

## 延遲

相同前 24 句 dev、八個 persona、兩個種子，單 worker 共 384 案例／
7,113 按鍵：修正前正式預設平均 0.36 ms、p95 1.90 ms；修正後平均
0.42 ms、p95 2.30 ms。詞模型 0.5 平均 1.45 ms、p95 7.10 ms，本批
最慢鍵 44.86 ms；啟動加一次短解碼 1.33 秒。這是單輪量測，沒有信賴區間。
略過原始／字典讀音相同時的重複查找；普通輸入仍有一點原始 span key
建構成本，沒有改動模型載入或約 170 MB 的容量。

前次模型報告在不同系統負載下較慢，不能把兩輪差距歸因於此次鎖定修正。
資料與執行檔雜湊亦保存在精簡結果 JSON 中。

## 驗證與 golden 更新

Zig 271 個單元／行為測試、Python 100 個、C ABI CLI 11 個測試通過。
Linux fcitx5 C1–C15、IBus headless、wasm playground 通過。
1,344 個解碼候選與 43,152 個完整候選／touch／Unicode golden 不變。

四組 session replay 的 changed cases 分別為 13／15／41／34（100/1、
100/487、400/1、400/487）。六個共同的 toned probe 曾選修復字後按 Return，
原先選字被忽略、送出原句；現在送出明確所選的字，例如 `早上好` 選「善」
送出 `早善好`。fuzz 中的修復選字也能影響刷新、之後的候選與提交。
已檢查這些差異並更新四份 golden；沒有更新 decoder/parity golden。
沒有 UI／adapter 改動，也未執行 GUI 自動化。
