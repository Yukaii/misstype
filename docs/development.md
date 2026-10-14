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
