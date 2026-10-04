# 開發、建置與發佈

這份文件收納原本放在 README 的開發者內容。使用者向的安裝與操作說明見 [README](../README.md)；開發循環與隱私原則見 [AGENTS.md](../AGENTS.md)。

## macOS 輸入法（建置與安裝）

macOS 輸入法以 SwiftPM InputMethodKit bundle 形式提供，建置階段引入經雜湊驗證的小麥注音詞庫資料。

```sh
# 執行 Swift 單元測試
swift test

# 建置發布版本並打包 App Bundle
./script/build_and_run.sh --build-only

# 安裝至 ~/Library/Input Methods 並自動載入
./script/install_ime.sh
```

不經 IME 客戶端、直接用打包後的詞庫做解碼診斷：

```sh
dist/MisstypeIME.app/Contents/MacOS/MisstypeIME --decode su3cl3
```

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

## Python 早期原型

最初的概念驗證切片（Python 3.11+、無外部執行期相依），用於驗證座標式觸控曲面輸入與取樣。解碼行為以 Swift `MisstypeCore` 為準，不要把解碼變更移植到 Python。

```sh
PYTHONPATH=src python -m unittest discover -s tests -v
PYTHONPATH=src python -m misstype.cli examples/hello.jsonl
PYTHONPATH=src python -m misstype.cli examples/keyboard-ni.jsonl
PYTHONPATH=src python -m misstype.cli examples/touch-ni-hao.jsonl
PYTHONPATH=src python tools/bench.py
```

測試軌跡使用 JSONL，能獨立於最終介面或硬體紀錄、遮蔽、比對與重放。可重放的詞組案例在 `tests/fixtures/`。
