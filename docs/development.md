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

`tools/typing_eval.py` 用 seed 固定的「打字者」把整句合成句子打進真正的 Zig `Session`（`misstype-dev --session-batch`），按 Return 後比對送出的文字。它量的是使用者最後拿到什麼，而不是單一層（解碼 top-1 見 `cursor_replay.py`、預覽穩定度見 `live_trace.py`、單鍵成本見 `mixed_latency.py`）。

```sh
(cd core-zig && zig build -Doptimize=ReleaseFast)   # Debug 的延遲不可比
python3 tools/typing_eval.py --baseline tools/baseline/typing_eval.json   # 與 baseline 比較
python3 tools/typing_eval.py --set dev --failures 10                      # 看失敗案例
python3 tools/typing_eval.py --bin <另一個 worktree>/core-zig/zig-out/bin/misstype-dev \
    --baseline tools/baseline/typing_eval.json                            # 比較兩個版本
```

- **打字者**：五個 persona（`careful`、`average`、`toneless`、`partial-tones`、`sloppy`），差別在聲調習慣（全打／不打／一半）、每鍵錯誤率（1–7 %，鄰鍵替換、對調、漏打、多打）與當場發現並用 Backspace 修掉的機率。中英混打有三種輸入方式：先按 Shift 再打英文（`shift-first`）、在注音模式打完英文才按 Shift（`shift-after`）、完全不切換、靠混打辨識（`no-switch`，開 `--mixed-english`）。
- **開迴路、可重放**：按鍵只由 (persona, 句子, seed) 決定，不看引擎輸出，所以兩次執行的差異只來自引擎。每個案例都存了按鍵序列，可以用 `misstype-dev --session-trace '<keys>' --show` 重放。`⇧` 是單獨輕按 Shift，`，。？！：` 是 Shift+標點，大寫字母是 Shift+該鍵。
- **指標**：整句完全正確率（`exact_pct`）、CER、每字按鍵數（KSPC）、預覽倒退／變動步數（同 `live_trace.py`）、每鍵延遲 p50／p95／max。依 track（`zh`、`mixed:<方式>`）× 句集與 × persona 分組。
- **流程**：在 dev 上找問題、調整，holdout 只用來確認。行為變更的 PR 跑 `--baseline` 並貼上 FIXED／BROKEN；有意的改善在同一個 PR 用 `--save tools/baseline/typing_eval.json` 更新 baseline（一個案例一行，diff 就是變動的案例）。`--fail-on-regression` 在任何組少了正確句時以 1 結束。

**限制**：persona 的參數是假設（熟練打字者約 1–3 % 按鍵出錯、多數當場修正），尚未用真實按鍵紀錄校準；打字者不會看預覽，也不會用游標選字補救，所以 `exact_pct` 是「不選字」的正確率；延遲受機器與平行數（`--jobs`）影響，只在同一台機器上比較。

2026-10-14 的 baseline（main `207221f`，2 seeds，1610 個案例）：純中文 dev／holdout 63.2 %／62.8 %（careful 86 %、toneless 53 %、sloppy 32 %）；失敗以長度正確但選錯字為主（219／296，多為同音字）。中英混打 `shift-first` 約 65 %；`shift-after` 只有 28 %／2.5 %，因為已經轉成中文的英文鍵在按 Shift 時不會被重讀；`no-switch` 56 %／32 %。

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
