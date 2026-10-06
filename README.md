# 隨打注音 (Misstype)

**繁體中文** | [English](README-en.md)

「隨打注音」（Misstype）是給注音使用者的輸入法，主打兩件事：

- **免聲調連續輸入**：不用打聲調，也不用逐字選字，一路打下去，輸入法依前後文組成整句。
- **自動修正打錯的字**：按錯鄰近的鍵、前後顛倒、多打或少打，都盡量還原成你想打的字，不影響正確輸入。

全程在本地運算、不需網路。專案仍在實驗階段，先用軟體驗證打字方式，再決定是否製作專用硬體。

> [!IMPORTANT]
> 本專案完全使用 LLM 開發，之後也會持續交給 LLM 開發、交付與測試。歡迎貢獻 bug 與 feature prompt；一般的貢獻同樣絕讚歡迎，不過要有被關掉、完全重改的心理準備 XD

## 為什麼又寫一個輸入法？

因為我自己想用。一開始只是想連眼睛都不睜開，一路隨便打下去，聲調懶得管，手指也不用很準，打完讓輸入法盡量猜回我想打的字。

以前用 Rime 的時候，想讓它學會一個詞，得先刻意打一遍、選對，再把多餘的字刪掉，我也不知道有沒有快速編輯詞庫的按鍵。Yahoo 奇摩輸入法和唯音用起來順手很多，這裡的「<kbd>Shift</kbd> + <kbd>←</kbd>/<kbd>→</kbd> 標記、<kbd>Return</kbd> 加詞」就是照他們的手感做的。

預設就免聲調、會自動修正，想要嚴格一點可以關掉。多種鍵盤排列、簡繁切換、倉頡速成目前不打算做。如果你只想要成熟穩定的日常輸入法，唯音很好用，直接用它就好；如果你也有類似的懶人需求，歡迎一起玩。

## 和其他注音輸入法比較

以下依各專案公開說明整理（2026-10-04 快照，未實測）；`-` 表示沒找到公開說明，不代表一定沒有。

| | 隨打注音 | ChiaKey | 唯音（vChewing） | 小麥注音 | Rime（鼠鬚管等） |
| --- | --- | --- | --- | --- | --- |
| 可省略聲調 | ✓ | - | 部分（注音狂打，預設停用） | - | ✓ |
| 自動修正打錯（鄰鍵、顛倒、多／少打） | ✓ | - | - | - | 部分（音節內順序；引擎另有預設關閉的打字修正） |
| 中英混打免切換 | ✓（macOS 預設關閉） | - | ✓ | - | -（需切換） |
| 修正英文拼錯 | ✓ | - | - | - | - |
| 自訂詞庫與學習 | ✓ | ✓ | ✓ | ✓ | ✓ |
| 預設離線 | ✓ | ✓ | ✓ | ✓ | ✓ |
| 支援系統 | macOS、Linux | macOS、Windows（預覽） | macOS | macOS、Windows、Linux、網頁（各為獨立專案） | macOS、Windows、Linux |

完整比較（平台、授權、安裝檔大小等）見[競品比較與功能研究](docs/competitors.md)。

## 安裝

### macOS

到 [GitHub Releases](https://github.com/Yukaii/misstype/releases/latest) 下載 `Misstype-<版本>.dmg`，開啟後執行 **Install Misstype**。輸入法安裝在你的使用者資料夾，不需要管理者密碼，之後會透過內建的 Sparkle 自動更新。第一次安裝後，登出再登入，即可在 macOS 選單列的輸入法選單或「系統設定 → 鍵盤 → 輸入方式」中選擇 **隨打注音**（英文系統顯示為 `Misstype Bopomofo`）。

### Linux

以 fcitx5 外掛支援 Linux，與 macOS 版共用同一個核心。安裝與進度見 [Linux 移植說明](docs/linux-port.md)。

從原始碼建置請見[開發、建置與發布](docs/development.md)。

## 打字操作指南

* **連續鍵入與免聲調**：聲調可選擇性鍵入；打字時邊打邊即時轉換，僅當前尚未拼完的注音符號會保留在組字區內。鍵入聲調鍵會立即完成該音節，<kbd>Space</kbd>（空白鍵）也代表第一聲（陰平）。
* **遞交輸入與注音文**：按下 <kbd>Enter</kbd> 鍵會直接遞交當前畫面上顯示的文字（包含尚未拼完的注音符號，支援注音文）；按下 <kbd>Shift</kbd> + <kbd>Enter</kbd> 則會將原始鍵入的注音符號直接輸出。
* **候選字選字模式**：按下 <kbd>↓</kbd> 或 <kbd>Tab</kbd>（亦可按 <kbd>←</kbd> 倒退至前方的詞彙）即可進入選字選單。選字時可使用鍵盤中間一排的 <kbd>asdfghjk</kbd> 快速鍵選取候選字（可在偏好設定調整；平常打字時這些鍵仍是正常的注音按鍵）。<kbd>Tab</kbd>／<kbd>Shift</kbd> + <kbd>Tab</kbd> 翻頁。按 <kbd>Esc</kbd> 退出選字模式；在一般打字狀態下按 <kbd>Esc</kbd> 則清空整個組字區。
* **全形符號與中英切換**：<kbd>Shift</kbd> + <kbd>數字鍵</kbd> 與 <kbd>Shift</kbd> + <kbd>=</kbd>、<kbd>[</kbd>、<kbd>]</kbd>、<kbd>&#96;</kbd> 可直接鍵入全形符號（！＠＃＄％︿＆＊（）＋｛｝～）。<kbd>Backspace</kbd> 可倒退修改原始組字內容。輕按單次 <kbd>Shift</kbd> 或按下 <kbd>Shift</kbd> + <kbd>Space</kbd> 即可直接遞交並切換中／英文模式。
* **我的詞庫**：打字時用 <kbd>Shift</kbd> + <kbd>←</kbd>/<kbd>→</kbd> 標記已轉換文字中的音節，按 <kbd>Return</kbd> 即可把詞（人名、專有名詞）加入自己的詞庫；對同一段標記再按 <kbd>Return</kbd> 則移除。macOS 的「設定 → 我的詞庫」是同一份 `user_dictionary.tsv` 的純文字編輯器，格式與唯音的 userdata 相同（`詞語 注音`，每行一筆），可直接貼上或用「匯入…」讀入唯音詞庫；只有一般詞彙清單時，可用 Will 保哥的第三方[線上產生器](https://vu.gh.miniasp.com/)（[原始碼](https://github.com/doggy8088/vChewing-userdata-generator)，MIT；與本專案無關）轉成此格式；Linux 請直接編輯 `~/.local/share/misstype/user_dictionary.tsv`。
* **在地化學習**：系統會在本地記憶各詞彙的選字偏好，單個漢字則會結合其前置上下文詞彙共同學習與加權。

## 授權條款

本專案採用 **MIT 授權條款**（詳見 [`LICENSE`](LICENSE)）。
隨附之詞庫資料衍生自小麥注音（MIT 授權） 與 libtabe（BSD 風格授權）；詳見 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
