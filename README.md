# 隨打注音 (Misstype)

**繁體中文** | [English](README-en.md)

「隨打注音」（Misstype）是一項探索**低干擾、無痛文字輸入體驗**的實驗專案：使用者能依照純粹的肌肉記憶連續打字，無需為了精準瞄準按鍵或頻繁停下選字而打斷思緒。輸入法會先捕捉音節輸入軌跡，並在短暫停頓或確認鍵入時，即時重組出流暢的中文、英文或中英混輸文字。

初期核心目標以**注音輸入法（Bopomofo）**與中英混輸為主，並搭載全本機離線解碼器。專案由軟體原型起步，在進行硬體設計前先充分驗證人機互動、解碼精準度與極致延遲表現。

## 文件導覽

- [產品規劃大綱 (Project Outline)](docs/project-outline.md)：產品初衷、各階段里程碑、實驗項目與成功指標。
- [技術架構說明 (Architecture)](docs/architecture.md)：分層設計、事件協定、解碼流水線與部署架構。
- [跨平台適配層規範 (Cross-Platform)](docs/cross-platform.md)：各平台適配器規範、按鍵傳遞規則與一致性驗證情境（C1～C12）。
- [Linux (fcitx5) 移植計畫 (Linux Port)](docs/linux-port.md)：Linux 移植現況、工具鏈、開發容器與測試驗證說明。
- [競品比較與功能研究](docs/competitors.md)：各專案功能對照、定位基準與追蹤維護原則。
- [開發與代理人指南 (AGENTS.md)](AGENTS.md)：開發循環、隱私原則與 Definition of Done。

本專案概念借鏡於 [青鍵 (Qingjian)](https://github.com/qingjian-team/qingjian)，特別是其平台無關的核心設計與整句延遲重組思維。隨打注音是一項獨立發展的實驗；與青鍵的相容性為長期里程碑，而非必然承諾。

## macOS 原生輸入法

macOS 原生輸入法以 SwiftPM InputMethodKit bundle 形式提供。在建置階段引入經雜湊驗證的小麥注音（McBopomofo）詞庫資料，並在無任何網路連線的前提下執行本機詞彙分詞與保守型容錯補正，完全免去每音節逐字選字的打斷感。

### 建置與安裝

```sh
# 執行 Swift 單元測試
swift test

# 建置發布版本並打包 App Bundle
./script/build_and_run.sh --build-only

# 安裝至 ~/Library/Input Methods 並自動載入
./script/install_ime.sh
```

安裝完成後，即可在 macOS 頂端狀態列輸入法選單中選擇 **隨打注音**（英文系統顯示為 `Misstype Bopomofo`）。

### 打字操作指南

* **連續鍵入與免聲調**：聲調可選擇性鍵入；打字時邊打邊即時轉換，僅當前尚未拼完的注音符號會保留在組字區內。鍵入聲調鍵會立即完成該音節，空白鍵（Space）亦代表第一聲（陰平）。
* **遞交輸入與注音文**：按下 `Enter` 鍵會直接遞交當前畫面上顯示的文字（包含尚未拼完的注音符號，支援注音文）；按下 `Shift + Enter` 則會將原始鍵入的注音符號直接輸出。
* **候選字選字模式**：按下 `向下鍵` 或 `Tab`（亦可按 `向左鍵` 倒退至前方的詞彙）即可進入選字選單。選字時可使用鍵盤基準行（Home-row）的 `asdfghjk` 快速鍵選取候選字（可於偏好設定調整；在一般打字模式下這些按鍵正常鍵入注音）。按 `Esc` 退出選字模式；在一般打字狀態下按 `Esc` 則清空整個組字區。
* **全形符號與中英切換**：`Shift + 數字鍵` 與 `Shift + = [ ] \`` 可直接鍵入全形符號（`！＠＃＄％︿＆＊（）＋｛｝～`）。`Backspace` 可倒退修改原始組字內容。輕按單次 `Shift` 或按下 `Shift + Space` 即可直接遞交並切換中／英文模式。
* **我的詞庫**：打字時用 Shift+←/→ 標記已轉換文字中的音節，按 Return 即可把詞（人名、專有名詞）加入自己的詞庫；對同一段標記再按 Return 則移除。macOS 的「設定 → 我的詞庫」是同一份 `user_dictionary.tsv` 的純文字編輯器；Linux 請直接編輯 `~/.local/share/mistype/user_dictionary.tsv`。
* **在地化學習**：系統會在本地記憶各詞彙的選字偏好，單個漢字則會結合其前置上下文詞彙共同學習與加權。

若要在沒有 IME 客戶端環境下進行解碼診斷測試，可直接執行：

```sh
dist/MistypeIME.app/Contents/MacOS/MistypeIME --decode su3cl3
```

當替換舊版輸入法時，安裝程式會將上一版備份於 `.cache/MistypeIME-previous.app`。如有需要，可透過指令停用該輸入法來源：
```sh
swift run -c release MistypeSourceTool disable
```

### 版本發布 (Releases)

推送 `v*` 標籤（git tag）至遠端將觸發 `.github/workflows/release.yml`，自動執行跨平台測試、透過 `script/package_release.sh` 建置通用二進位檔（Universal: `arm64` + `x86_64`），並在 GitHub Releases 發布 `Mistype-<version>.dmg`。

本地端亦可直接執行 `./script/package_release.sh 0.2.0`。使用者只需將 DMG 內的 `MistypeIME.app` 拖曳至 `Input Methods` 替換連結（`/Library/Input Methods`，需管理者密碼授權），登出後重新登入或於系統設定中加入即可。

專案支援 Developer ID 簽名與 Notarization 公證（透過 GitHub Secrets 配置）：
* `MACOS_CERT_P12_BASE64`、`MACOS_CERT_PASSWORD`：Developer ID 應用程式憑證
* `NOTARY_KEY_P8_BASE64`、`NOTARY_KEY_ID`、`NOTARY_ISSUER_ID`：用於 `notarytool` 之 App Store Connect API 金鑰

若未配置上述金鑰，產出的 DMG 將採用 Ad-hoc 簽署；於其他機器安裝後需手動解除隔離屬性：
```sh
xattr -dr com.apple.quarantine "/Library/Input Methods/MistypeIME.app"
```

## Linux (fcitx5) 支援

隨打注音透過 C++ fcitx5 外掛支援 Linux 平台，完全共用相同的核心庫 `MistypeCore` 與 C ABI 介面（`MistypeCAPI`）：

```sh
# 在 Docker 開發容器中執行編譯與無頭測試
script/linux/dev.sh 'script/linux/build.sh && script/linux/test_fcitx5.sh'
```

更多架構細節與進度請參閱 [Linux 移植說明 (docs/linux-port.md)](docs/linux-port.md) 與 [跨平台規範 (docs/cross-platform.md)](docs/cross-platform.md)。

## M0 早期原型重放 (Python)

專案最初的概念驗證切片基於 Python 3.11+ 撰寫，無外部執行期相依套件，主要用於驗證座標式觸控曲面輸入與取樣：

```sh
PYTHONPATH=src python -m unittest discover -s tests -v
PYTHONPATH=src python -m mistype.cli examples/hello.jsonl
PYTHONPATH=src python -m mistype.cli examples/keyboard-ni.jsonl
PYTHONPATH=src python -m mistype.cli examples/touch-ni-hao.jsonl
PYTHONPATH=src python tools/bench.py
```

測試用例使用 JSONL 格式儲存軌跡，能獨立於最終介面或硬體進行紀錄、遮蔽、比對與重放。可重放的詞組測試案例位於 `tests/fixtures/`。

## 授權條款 (License)

本專案採用 **MIT 授權條款**（詳見 [`LICENSE`](LICENSE)）。
隨附之詞庫資料衍生自小麥注音 McBopomofo (MIT) 與 libtabe (BSD 風格授權)；詳見 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
