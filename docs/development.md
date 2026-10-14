# 開發、建置與發佈

這份文件收納原本放在 README 的開發者內容。使用者向的安裝與操作說明見 [README](../README.md)；開發循環與隱私原則見 [AGENTS.md](../AGENTS.md)。

## macOS 輸入法（建置與安裝）

macOS 輸入法以 SwiftPM InputMethodKit bundle 形式提供，建置階段引入經雜湊驗證的小麥注音詞庫資料。

```sh
# 先建置通用的 Zig 核心動態庫（輸入法連結它）
./script/zig/build_macos.sh

# 執行 Swift 單元測試（UI 端的 MisstypeMacKit；核心測試在 core-zig：cd core-zig && zig build test）
swift test

# 建置發布版本並打包 App Bundle
./script/build_and_run.sh --build-only

# 安裝至 ~/Library/Input Methods 並自動載入
./script/install_ime.sh
```

`install_ime.sh` detects the host architecture and builds only that Zig slice,
so local installs on Apple Silicon do not spend time compiling the Intel
target. `script/zig/build_macos.sh` without `MISSTYPE_MACOS_ARCH=native` still
builds the universal library used by release packaging.

不經 IME 客戶端、直接用打包後的詞庫做解碼診斷（Zig 開發用 CLI）：

```sh
(cd core-zig && "$(../script/zig/bootstrap.sh)" build)
MISSTYPE_RESOURCES=dist/MisstypeIME.app/Contents/Resources \
    core-zig/zig-out/bin/misstype-dev --decode su3cl3
```

重現使用者回報的按鍵序列（`--show` 顯示每鍵後的組字區與游標）：
`dist/MisstypeIME.app/Contents/MacOS/MisstypeIME --session-trace 'su3cl3' --show`，或同樣參數的 `misstype-dev --session-trace`。

替換舊版時，安裝程式會把上一版備份於 `.cache/MisstypeIME-previous.app`。需要停用輸入法來源時：

```sh
swift run -c release MisstypeSourceTool disable
```

## 版本發布

推送 `v*` 標籤會觸發 `.github/workflows/release.yml`：跨平台測試、透過 `script/package_release.sh` 建置同時支援 Apple 晶片與 Intel 的通用版本，並在 GitHub Releases 發布 `Misstype-<version>.dmg`。本機也可執行 `./script/package_release.sh 0.2.0`。

簽署與公證由 GitHub Secrets 驅動（皆為選用）：

| Secret | 用途 |
| --- | --- |
| `MACOS_CERT_P12_BASE64`、`MACOS_CERT_PASSWORD` | Developer ID 應用程式憑證 |
| `NOTARY_KEY_P8_BASE64`、`NOTARY_KEY_ID`、`NOTARY_ISSUER_ID` | `notarytool` 使用的 App Store Connect API 金鑰 |

未配置時 DMG 採臨時簽署，在其他機器安裝後需手動解除隔離屬性：

```sh
xattr -dr com.apple.quarantine "/Library/Input Methods/MisstypeIME.app"
```

DMG 安裝器、Sparkle 自動更新與驗證狀態見 [打包、安裝程序與自動更新](release.md)。

## Linux（fcitx5）

```sh
# 在 Docker 開發容器中執行編譯與無頭測試
script/linux/dev.sh 'script/linux/build.sh && script/linux/test_fcitx5.sh'

# 全部層級（核心測試、C ABI、fcitx5 無頭測試）
script/linux/dev.sh 'bash script/linux/test_all.sh'
```

細節見 [Linux 移植計畫](linux-port.md) 與 [跨平台適配層規範](cross-platform.md)。

## 打字評估（模擬真實打字）

`tools/typing_eval.py` 用 seed 固定的「打字者」把整句合成句子打進真正的 Zig `Session`（`misstype-dev --session-batch`），再像人一樣看畫面用選字補救，按 Return 後比對送出的文字。它量的是使用者實際付出的成本，而不是單一層（解碼 top-1 見 `cursor_replay.py`、預覽穩定度見 `live_trace.py`、單鍵成本見 `mixed_latency.py`）。

```sh
(cd core-zig && zig build -Doptimize=ReleaseFast)   # Debug 的延遲不可比
python3 tools/typing_eval.py --baseline tools/baseline/typing_eval.json   # 與 baseline 比較（約 20 秒）
python3 tools/typing_eval.py --set dev --failures 10                      # 看需要補救的案例
python3 tools/typing_eval.py --bin <另一個 worktree>/core-zig/zig-out/bin/misstype-dev \
    --baseline tools/baseline/typing_eval.json                            # 比較兩個版本
```

- **語料**（`tools/eval/typing_corpus.tsv`）：約 350 句手寫合成句，依類別分層：日常、同音字、破音字、斷詞歧義、工作、數字、長句、標點、中英混打。`auto` 列依句子的 md5 分到 dev／holdout，作者無法挑選。句子不得取自 HPLT（`homophone.bin` 的訓練資料），否則同音字的數字會虛高。讀音由詞庫推導；推導錯時在第四欄手寫。
- **打字者**：`careful`、`average`、`toneless`、`partial-tones`、`sloppy`，差別在聲調習慣、每鍵錯誤率（1–7 %，鄰鍵替換、對調、漏打、多打）與當場用 Backspace 修掉的機率。中英混打有三種輸入方式：`shift-first`（先按 Shift）、`shift-after`（在注音模式打完英文才按 Shift）、`no-switch`（不切換，開 `--mixed-english`）。
- **對照組**：`clean`（打聲調）、`clean-toneless`（不打聲調）與 `clean-partial-tones`（逐音節以固定 seed 隨機省略 50 % 聲調）都不打錯字，所以它們的補救成本完全來自引擎。部分聲調對照組把音節切分歧義和 `partial-tones` 的按鍵／聲調錯誤分開量，不是人類習慣的實測。新增 persona 不改變既有 persona 的按鍵；它們各自有獨立的 seed。`clean` 的 `unreach_pct` 應為 0：不為 0 時，代表讀音推導錯了，或修正者的策略有漏洞，要先查清楚。
- **修正者**（`dev.zig` 的 `correct`）：在第一個錯字處，若整句候選在第一頁就直接選（`↓` 加選字鍵）；否則把詞游標往錯字方向移，在每一站讀候選，選出在該位置符合目標的最長詞（同頁用選字鍵，否則 `↓`／`↑` 再 `⏎`），最後按 `⏎` 走出游標並送出。每個鍵都是真實事件。`MISSTYPE_FIX_DEBUG=1` 會印出每一步。
- **指標**：`exact_pct`（不用選字就對）、`picks_100`（每百字選字次數，只計能修好的句子）、`fix_keys`（每句補救按鍵數）、`unreach_pct`（選字修不好、只能重打）、`space_lost`（只差在空白）、CER、KSPC、預覽變動步數、每鍵延遲。依 track × 句集、× persona、× 類別分組。
- **可重放**：打字者是開迴路，按鍵只由 (persona, 句子, seed) 決定；修正者是確定性的。所以兩次執行的差異只來自引擎。每個案例都存了按鍵序列，可以用 `misstype-dev --session-trace '<keys>' --show` 重放；`⇧` 是單獨輕按 Shift，`，。？！：` 是 Shift+標點，大寫字母是 Shift+該鍵。
- **流程**：在 dev 上找問題、調整，holdout 只用來確認。行為變更的 PR 跑 `--baseline` 並貼上 FEWER／MORE PICKS；有意的改善在同一個 PR 用 `--save tools/baseline/typing_eval.json` 更新 baseline（一個案例一行，diff 就是變動的案例）。`--fail-on-regression` 在任何案例要多選字，或任何組變差時以 1 結束。

- **學習**（`--learning clean,clean-toneless,...`）：每個 persona 用同一個 engine（`--session-batch --carry`）依序打 dev（首次）、再打一次 dev（重打）、再打 holdout（轉移），每一輪都和全新 engine 打同樣的按鍵比較。重打變少是「記住了」，轉移變少是「學到的能推廣」，轉移變多是「學習造成的副作用」。`--learned-out PATH` 會把 engine 學到的內容寫出來。

**限制**：persona 的參數是假設（熟練打字者約 1–3 % 按鍵出錯、多數當場修正），尚未用真實按鍵紀錄校準。打字者打字時不看預覽，只在打完後補救。修正者不會重打，也不會用 Shift+←／→ 標記詞。延遲受機器負載與平行數（`--jobs`）影響，只在同一台機器上比較。

2026-10-14 的 baseline（`5025cbc` 加上這份語料，2 seeds，6300 個案例）：

- **純中文**：`clean` 有 89.8 % 不用選字、每百字選 1.5 次；`clean-toneless` 只有 66.0 %、每百字選 **5.8 次**。不打聲調時的選字負擔幾乎全來自引擎（同音字、跨聲調的選擇），是最大的改善空間。依類別看，數字（6.2）、同音字（4.6）、工作（4.3）的每百字選字次數最高。
- **只能重打**：`clean-toneless` 有 1 %（例如 `gji` 被切成「說」而不是「是我」：選字無法重新切開音節）；其餘的只能重打都來自打字者沒發現的錯字。
- **中英混打**：`shift-first` 68.5 % 不用選字；`shift-after` 只有 19.9 %，而且 75 % 只能重打。原因是英文鍵已經轉成中文、按 Shift 時不會重讀；更糟的是，有時會連前面的中文也一起改成英文字母（`fu/3183email`）。`no-switch` 54.8 %，開頭小寫字母常被讀成注音（`iPhone` → `喔Phone`）。

## 離線解碼參數校準實驗

假設：現有詞頻／音韻模型的少數全域權重，能在開發集不同句子上穩定減少
選字，且不增加只能重打的句子。最小反證實驗固定九組設定：每詞成本
0.25／0.5／0.75，既有上下文三種權重一起乘 0.75／1／1.25。
不調個別字詞，不改修正成本，不使用既有 holdout 選參數。

同一句的所有 persona 和 seed 必須在同一折。每折只用其餘句子選設定，
再評估未參與選擇的句子；選擇時保護各 persona 的可修復率，以及無錯字
對照組的免選字率。同分偏好現有預設。既有開發句曾參與先前實驗，
所以這是校準穩定性檢查，不能宣稱是新盲測；結果成立後仍需獨立新資料。

```sh
python3 tools/calibrate_decoder.py --out .cache/decoder-calibration/report.json
# 中斷後重跑：只重用執行檔、詞庫、按鍵、persona 和工具雜湊都吻合的結果
python3 tools/calibrate_decoder.py --out .cache/decoder-calibration/report.json --resume
```

工具只跑純中文 dev，逐組串行執行真正的 Session，保留每鍵延遲與可重放的
按鍵；不讀寫個人學習檔、不改產品預設或打字 baseline。報告中的
`eligible_for_new_blind_test` 只代表開發集分折檢查通過，不代表可以出貨。
選擇順序是只能重打的案例數、選字總次數、退步案例數，再偏好接近現值。
選字只計可修復案例，所以各 persona 的可修復率另設保護條件。

2026-10-14 結果：145 句 × 8 persona × 2 seeds = 2,320 案例。
五折都選每詞成本 0.75、上下文維持原值；折外 18 個案例少選字、0 個多選字，
選字總次數 386 → 356，可修復率與無錯字對照組沒有退步。固定這個選擇後，
既有 holdout 3,584 案例（含中英混打）55 個少選字、19 個多選字，無聲調
對照組免選字率 69.8 → 68.5 %，並有兩個中英混打案例從可修復變成只能重打。
因此拒絕這次預設值調整，保持 0.5，沒有再用 holdout 挑另一組。
重現紀錄見 `tests/fixtures/word-penalty-calibration.md`。

下一個假設應針對一致的詞級機率與音韻修正成本，以及分數會改變搜尋範圍的
邊界來設計；先保留新獨立測試資料，再做帶平滑／回退的詞級模型實驗。

搜尋邊界反證實驗：額外的修正切分只在初輪沒有任何完整、零修正候選時
開啟，而不依初輪第一名決定。假設它能避免語言權重改變搜尋範圍，
又不增加現值 0.5 下的選字／重打成本。先跑既有 dev；若噪聲輸入
需要更多補救，拒絕此規則，不從 holdout 找另一個門檻。開發用開關
`MISSTYPE_REPAIR_REQUIRES_NO_CLEAN=1`，產品預設不變。

結果：固定每詞成本 0.75 的重現中，額外搜尋的「我先取消」消失，但排名仍是
「我想去洗澡」在「我先去洗澡」前。現值 0.5 的 dev 3,616 案例選字改善／
退步 0／0，可修復率與補救按鍵數不變，純中文預覽變動 1,772 → 1,792 步。
初輪與完整 baseline 比較的兩個補救按鍵差異，在相同批次順序的成對重跑中
消失，不能歸因於此門檻。因沒有最終成本改善，只保留停用的開發消融開關。
新外部評估定義已先封存於
`tools/eval/external_v1.json`，重建方法與限制見
[offline-evaluation.md](offline-evaluation.md)；這輪不使用其解碼結果。

## 詞級模型原型（尚未採用）

假設：在同一份詞庫分詞後，用包含所有詞對的完整計數建立帶絕對折扣與
unigram 回退的條件機率，在 Zig 的詞路徑搜尋內插分數，可減少無聲調選字。
既有同音 bigram 只存有歧義詞對且刪掉低次數項，不能直接當完整機率模型。
最小實驗使用四個已快取、雜湊固定的 HPLT 分片，各取前 10,000 文件。
固定折扣 0.75、unigram 加一平滑；只在 dev 比較內插權重 0.1／0.25／0.5，
保留音韻修正成本、每詞成本 0.5 與原搜尋門檻。新模型啟用時取代後段 PMI
加分，避免上下文重複計分。未載入或權重 0 時輸出必須保持一致。
模型固定且 dev 有收益、不降低無錯字對照組或可修復率後，才看封存外部集。
若 dev 不成立，拒絕原型，保持封存資料未使用。

結果與限制見 [offline-word-model.md](offline-word-model.md)：權重 0.5 有
252 個選字改善、57 個退步，無聲調正確率提高，但部分聲調錯字組可修復率
下降，未採用。外部 200 句未解碼；正式預設與 baseline 保持不變。

## Python 早期原型

最初的概念驗證切片（Python 3.11+、無外部執行期相依），用於驗證座標式觸控曲面輸入與取樣。解碼行為以 Zig 核心（`core-zig/`）為準，不要把解碼變更移植到 Python。

```sh
PYTHONPATH=src python -m unittest discover -s tests -v
PYTHONPATH=src python -m misstype.cli examples/hello.jsonl
PYTHONPATH=src python -m misstype.cli examples/keyboard-ni.jsonl
PYTHONPATH=src python -m misstype.cli examples/touch-ni-hao.jsonl
PYTHONPATH=src python tools/bench.py
```

測試軌跡使用 JSONL，能獨立於最終介面或硬體紀錄、遮蔽、比對與重放。可重放的詞組案例在 `tests/fixtures/`。


### 詞模型 Session 修復可達性實驗（2026-10-14）

假設：Session 的穩定前綴鎖定與游標詞候選使用不同的修復集合，使完整
解碼已有的詞無法在手動補救時出現。先以 `ej tk c96ao6x96` 的純合成反例
比較 Session 的整句／各游標列表與完整解碼，再建立不依賴大型模型的
最小詞庫測試。修正必須保留原始按鍵、音韻成本、明確選字鎖定與無錯字
對照結果；只在原先模型與權重 0.5 上成對重跑 dev，不再尋找新參數。
外部 200 句保持未使用。若原因在評估工具，修正評估而非更改產品規則。


結果：原始輸入與修復後字典讀音的選字鎖定 key 不一致；修正查找後，
正式預設 7,200 案例 FIXED 11／BROKEN 0，並更新 baseline。模型仍在
部分聲調錯字組多一個不可修復案例（42 → 43），未採用；外部資料未使用。
詳細驗證、反例及 replay 更新見 [repair-pick.md](repair-pick.md)。


### 部分聲調切分反例的標點選單檢查（2026-10-14）

先前「我遲到了 → 握到了」可能是候選切分失去補救路徑的判斷，已被
逐鍵重放反證：句號後的列表是標點選單，Esc 關閉後整句正確候選仍在
第一頁。假設是模擬修正者漏掉了這個可用操作，而不是 Zig 切分丟失。
最小實驗用不依賴模型的合成詞庫，讓 `jit42l4xk7。` 顯示「握到了。」
且整句列表另有「我遲到了。」；修正者必須關閉標點選單，再用原有的
整句選字規則補救。按鍵全是 Session 真實事件，Esc 計入補救成本。
只修改開發 CLI 的模擬修正者，固定模型 0.5 與同批 dev，另重算原預設
7,200 個案例；首選文字應不變。封存外部集保持未使用。


結果：確認是標點選單遮住整句列表；修正者關選單後能選回四音節候選。
原預設 7,200 案例首選／最終文字不變（FIXED 0／BROKEN 0），補救按鍵
淨減 77。固定模型 0.5 的部分聲調錯字組不可修復數為 42，與原預設相同，
dev 守門通過。修正 protocol 已記錄為 `punctuation-escape-v1`；外部資料
仍未使用。重現與可比性限制見 [punctuation-correction.md](punctuation-correction.md)。


### 網頁可用的稀疏詞模型（2026-10-14）

假設：原型的大部分低頻詞對可以回退至 unigram，只保留固定的 50,000／
200,000 個最高計數詞對，並以 32-bit 機率及詞 ID 存表，可把約 170 MB
縮成 5 MB 以下，同時保留 dev 的實際選字收益。它是有損剪枝，不是假設
壓縮一定不掉品質。保留原 unigram、BOS/EOS/UNK，剪掉的機率質量全部
回退，條件分布仍須正規化；同時計算 gzip 下載量、native 峰值 RSS 與
WASM linear-memory 高水位。權重固定 0.5，基準含 PR #83 的現有小表。
只比較已固定的兩個容量，不以外部 200 句找剪枝或權重參數。產品預設
維持現有小表，新增網頁載入能力是明確選用的實驗。


稀疏完整模型的 50k／200k 容量均未通過 dev 守門。依「極小、快、可攜」
的取捨需求，再以 PR #83 相同、已釘選來源與 export 參數建立固定 50k／
100k 重排表（0.4／0.8 MB），加上無上下文表作下限。這是另一個事先固定
的容量比較，沒有新權重或新評估句子；不把縮小後的減損隱藏成總平均收益。

結果：0.4／0.8 MB PMI 表保留無表→現有表約 72%／78% 的首選增益，
但仍未通過替換現有 2.4 MB 表的守門。完整 LM 的收益成本太高，固定稀疏
LM 也未通過。保留預設；實作包含格式正規化驗證、明確選用的 WASM
載入與 fallback、native／WASM paired framework。數據、資源 hash、
記憶體定義與重跑指令見 [lightweight-models.md](lightweight-models.md)。

### 詞典索引的生命週期量測（2026-10-14）

假設：英文 symmetric-delete 索引建置時的逐詞去重表、重複變體與
輸入順序陣列滯留長期 arena，造成可避免的記憶體占用。最小實驗只把
建置暫存放到可重用／釋放的 scratch，索引新 key 才複製到長期 arena。
不刪詞、不改 fuzzy 規則或候選順序。先固定 baseline binary／WASM，
分開量測中文無 override、中文含 toneless override、英文的 arena 容量、
native 峰值 RSS 與建置時間；再重放固定 384 案例量 key latency／WASM
高水位，並用既有完整打字 baseline 與 golden 驗證行為一致。
封存外部集不使用；browser-WASI 容量不當成瀏覽器 RSS。


結果：7,200 個打字案例逐案 0 差異，四組 replay golden、parity 與
WASM 測試一致。英文索引建置的 native 峰值 RSS 106.8 → 92.0 MiB；
含英文的 typing batch 峰值 209.7 → 189.2 MiB，中文 batch 167.2 →
153.5 MiB（開發 CLI 預載英文）。WASM 載入英文後 linear memory
224.5 → 189.7 MB，打完 384 案例 273.7 → 237.8 MB，native 首選
mismatch 0。中文詞庫數值不變。代價是每個新 key 多複製一次：native
英文建置中位數 46.9 → 49.0 ms（交錯 15 次）；key latency 不變。WASM
計時在高負載主機上離群值超過差距，未能判定。`arena_bytes` 是幾何成長
的 arena 節點大小總和，英文反而 153.9 → 173.3 MB，不能當節省量。
剩餘大宗是 posting 清單：333k 筆 posting 配了 2.67M 槽，約 8 倍。
固定結果在 `tools/eval/index_memory_v1.json`；重跑：
`zig build -Doptimize=ReleaseFast install index-memory` 後執行
`python3 tools/index_memory_eval.py --probe … --dev … --out … [--baseline …]`
與 `node tools/wasm_model_eval.mjs <out> --baseline-only --wasm=<wasm>`。

### 英文 posting 精確配置（2026-10-14）

假設：英文刪字索引剩下的大宗是 posting 清單的預留容量；333k 筆
posting 配了 2.67M 槽，因為多數 key 只有一個詞卻各預配 8 槽。最小
實驗改成兩段建置：先計數，再把全部 posting 依原詞序填入單一連續陣列，
map 值改為 `(start, len)`。WASM linear memory 不會縮，故不採「先成長
再壓實」，避免建置尖峰留在高水位。不改 key、詞序或 fuzzy 規則；同一
key 的 posting 順序不變，所以候選應逐案一致。以上一個 commit 為
baseline，重用 `index_memory_eval.py` 的 native RSS／7,200 案例／
384 案例延遲與 WASM 高水位；建置多一次變體列舉，預期初始化略慢。

結果：7,200 案例 0 差異，四組 replay golden、parity、decode 與 WASM
測試一致。posting 槽數 2.67M → 333,281（= 筆數）。英文索引 native
峰值 RSS 92.0 → 39.4 MiB；typing batch 峰值中文 153.5 → 101.8、
混打 189.2 → 138.3 MiB；key latency 不變。WASM 載入英文後 linear
memory 189.7 → 156.0 MB，打完 384 案例 237.8 → 204.2 MB，首選
mismatch 0；wasm32 指標只有 4 bytes，省下比例小於 native。代價是
變體列舉兩次：native 英文建置中位數 48.4 → 52.3 ms（交錯 15 次）。
固定結果在 `tools/eval/index_memory_v2.json`。
