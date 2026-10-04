# 隨打注音 (Misstype)

**繁體中文** | [English](README-en.md)

「隨打注音」（Misstype）是給注音使用者的輸入法，主打兩件事：

- **免聲調連續輸入**：不用打聲調，也不用逐字選字，一路打下去，輸入法依前後文組成整句。
- **自動修正打錯的字**：按錯鄰近的鍵、前後顛倒、多打或少打，都盡量還原成你想打的字，不影響正確輸入。

全程在本機運算、不需網路。專案仍在實驗階段，先用軟體驗證打字方式，再決定是否製作專用硬體。

## 和其他注音輸入法比較

以下依各專案公開說明整理（2026-10-04 快照，未實測）；`-` 表示沒找到公開說明，不代表一定沒有。

| | 隨打注音 | Ari IME | ChiaKey | Bopomix | KeyKey（琦琦） | ZingIME（晶晶） |
| --- | --- | --- | --- | --- | --- | --- |
| 可省略聲調 | ✓ | - | - | - | - | - |
| 自動修正打錯（鄰鍵、顛倒、多／少打） | ✓ | - | - | - | - | - |
| 中英混打免切換 | ✓（macOS 預設關閉） | ✓ | - | ✓ | - | ✓ |
| 修正英文拼錯 | ✓ | - | - | - | - | - |
| 自訂詞庫與學習 | ✓ | ✓ | ✓ | ✓ | ✓ | - |
| 預設離線 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 支援系統 | macOS、Linux | Linux | macOS、Windows（預覽） | macOS | macOS、Windows、Linux、手機 | macOS |

完整比較（平台、授權、安裝檔大小等）見[競品比較與功能研究](docs/competitors.md)。

## 文件導覽

- [產品規劃大綱](docs/project-outline.md)：產品初衷、各階段里程碑、實驗項目與成功指標。
- [技術架構說明](docs/architecture.md)：分層設計、事件協定、解碼流水線與部署架構。
- [跨平台適配層規範](docs/cross-platform.md)：各平台適配器規範、按鍵傳遞規則與一致性驗證情境（C1～C12）。
- [Linux 移植計畫](docs/linux-port.md)：Linux 移植現況、工具鏈、開發容器與測試驗證說明。
- [競品比較與功能研究](docs/competitors.md)：各專案功能對照、定位基準與追蹤維護原則。
- [組詞與解碼引擎技術研究](docs/decoding-engines.md)：DAG、Bigram、Rime、神經模型與統一容錯網格之演算法與工程權衡。
- [打包、安裝程序與自動更新](docs/release.md)：DMG 安裝器、Sparkle 自動更新、簽章與發佈流程。
- [開發與代理人指南](AGENTS.md)：開發循環、隱私原則與 Definition of Done。

本專案概念借鏡於 [青鍵 (Qingjian)](https://github.com/qingjian-team/qingjian)，特別是其平台無關的核心設計與整句延遲重組思維。隨打注音是一項獨立發展的實驗；與青鍵的相容性為長期里程碑，而非必然承諾。

## macOS 原生輸入法

macOS 原生輸入法以 SwiftPM InputMethodKit bundle 形式提供。在建置階段引入經雜湊驗證的小麥注音詞庫資料，並在完全離線的情況下於本機斷詞、修正打錯的字，不必每個音節都停下來選字。

### 建置與安裝

```sh
# 執行 Swift 單元測試
swift test

# 建置發布版本並打包 App Bundle
./script/build_and_run.sh --build-only

# 安裝至 ~/Library/Input Methods 並自動載入
./script/install_ime.sh
```

安裝完成後，即可在 macOS 選單列的輸入法選單中選擇 **隨打注音**（英文系統顯示為 `Misstype Bopomofo`）。

### 打字操作指南

* **連續鍵入與免聲調**：聲調可選擇性鍵入；打字時邊打邊即時轉換，僅當前尚未拼完的注音符號會保留在組字區內。鍵入聲調鍵會立即完成該音節，空白鍵也代表第一聲（陰平）。
* **遞交輸入與注音文**：按下 `Enter` 鍵會直接遞交當前畫面上顯示的文字（包含尚未拼完的注音符號，支援注音文）；按下 `Shift + Enter` 則會將原始鍵入的注音符號直接輸出。
* **候選字選字模式**：按下 `向下鍵` 或 `Tab`（亦可按 `向左鍵` 倒退至前方的詞彙）即可進入選字選單。選字時可使用鍵盤中間一排的 `asdfghjk` 快速鍵選取候選字（可在偏好設定調整；平常打字時這些鍵仍是正常的注音按鍵）。按 `Esc` 退出選字模式；在一般打字狀態下按 `Esc` 則清空整個組字區。
* **全形符號與中英切換**：`Shift + 數字鍵` 與 `Shift + = [ ] \`` 可直接鍵入全形符號（`！＠＃＄％︿＆＊（）＋｛｝～`）。`Backspace` 可倒退修改原始組字內容。輕按單次 `Shift` 或按下 `Shift + Space` 即可直接遞交並切換中／英文模式。
* **我的詞庫**：打字時用 Shift+←/→ 標記已轉換文字中的音節，按 Return 即可把詞（人名、專有名詞）加入自己的詞庫；對同一段標記再按 Return 則移除。macOS 的「設定 → 我的詞庫」是同一份 `user_dictionary.tsv` 的純文字編輯器，格式與 vChewing 的 userdata 相同（`詞語 注音`，每行一筆），可直接貼上或用「匯入…」讀入 vChewing 詞庫；只有一般詞彙清單時，可用保哥的[線上產生器](https://vu.gh.miniasp.com/)（[原始碼](https://github.com/doggy8088/vChewing-userdata-generator)）轉成此格式；Linux 請直接編輯 `~/.local/share/mistype/user_dictionary.tsv`。
* **在地化學習**：系統會在本地記憶各詞彙的選字偏好，單個漢字則會結合其前置上下文詞彙共同學習與加權。

若要在沒有 IME 客戶端環境下進行解碼診斷測試，可直接執行：

```sh
dist/MistypeIME.app/Contents/MacOS/MistypeIME --decode su3cl3
```

當替換舊版輸入法時，安裝程式會將上一版備份於 `.cache/MistypeIME-previous.app`。如有需要，可透過指令停用該輸入法來源：
```sh
swift run -c release MistypeSourceTool disable
```

### 版本發布

推送 `v*` 開頭的版本標籤將觸發 `.github/workflows/release.yml`，自動執行跨平台測試、透過 `script/package_release.sh` 建置同時支援 Apple 晶片與 Intel 的通用版本，並在 GitHub Releases 發布 `Mistype-<version>.dmg`。

本地端亦可直接執行 `./script/package_release.sh 0.2.0`。使用者只需將 DMG 內的 `MistypeIME.app` 拖曳至 `Input Methods` 替換連結（`/Library/Input Methods`，需管理者密碼授權），登出後重新登入或於系統設定中加入即可。

專案支援 Apple 開發者簽署與公證（透過 GitHub Secrets 配置）：
* `MACOS_CERT_P12_BASE64`、`MACOS_CERT_PASSWORD`：Developer ID 應用程式憑證
* `NOTARY_KEY_P8_BASE64`、`NOTARY_KEY_ID`、`NOTARY_ISSUER_ID`：用於 `notarytool` 之 App Store Connect API 金鑰

若未配置上述金鑰，產出的 DMG 將採用 臨時簽署；於其他機器安裝後需手動解除隔離屬性：
```sh
xattr -dr com.apple.quarantine "/Library/Input Methods/MistypeIME.app"
```

## Linux 支援

隨打注音以 fcitx5 外掛支援 Linux，和 macOS 版共用同一個核心程式庫：

```sh
# 在 Docker 開發容器中執行編譯與無頭測試
script/linux/dev.sh 'script/linux/build.sh && script/linux/test_fcitx5.sh'
```

更多架構細節與進度請參閱 [Linux 移植說明 (docs/linux-port.md)](docs/linux-port.md) 與 [跨平台規範 (docs/cross-platform.md)](docs/cross-platform.md)。

## 早期原型重放（Python）

專案最初的概念驗證切片基於 Python 3.11+ 撰寫，無外部執行期相依套件，主要用於驗證座標式觸控曲面輸入與取樣：

```sh
PYTHONPATH=src python -m unittest discover -s tests -v
PYTHONPATH=src python -m mistype.cli examples/hello.jsonl
PYTHONPATH=src python -m mistype.cli examples/keyboard-ni.jsonl
PYTHONPATH=src python -m mistype.cli examples/touch-ni-hao.jsonl
PYTHONPATH=src python tools/bench.py
```

測試用例使用 JSONL 格式儲存軌跡，能獨立於最終介面或硬體進行紀錄、遮蔽、比對與重放。可重放的詞組測試案例位於 `tests/fixtures/`。

## 授權條款

本專案採用 **MIT 授權條款**（詳見 [`LICENSE`](LICENSE)）。
隨附之詞庫資料衍生自小麥注音（MIT 授權） 與 libtabe（BSD 風格授權）；詳見 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
