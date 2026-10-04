# 競品比較與功能研究

[繁體中文](competitors.md) | [English](competitors-en.md)

資料快照：2026-10-04。以下內容整理自各專案公開的 README、發行頁面或官方網站；ZingIME 另參考一則媒體摘要。這些是專案對外宣稱的功能，未實際安裝或基準測試。`-` 代表「未找到公開說明」，不代表功能不存在。

本比較表並非各輸入法的優劣評比，而是作為專案開發時的設計基準與參考坐標：[唯音（vChewing，原威注音）](https://github.com/vChewing/vChewing-macOS) 作為成熟、穩定的日常主力參考；Misstype 則專注於驗證兩項實驗性設計——免切換的中英混打學習，以及將模糊輸入配對回候選讀法。

> **公開前待辦事項：** 本文為 2026-10-04 整理之快照。公開前需重新核對各專案最新版本與安裝檔大小、確認矩陣中的 `-` 與 ZingIME 相關資訊（定價、AI 選字機制、磁碟佔用），並補查「研究缺口」所列之輸入法。缺乏明確來源之內容應刪除或調整為保守陳述，並確認各專案之語氣與授權描述客觀公允。

## 專案比較

| 專案 | 平台 | 注音引擎 | 中英混輸（免切換） | 學習 | AI／網路 | 下載大小 | 授權／價格 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [Ari IME](https://github.com/kaiyasi/Ari-IME) | Linux（fcitx5）、WASM 核心 | libchewing 詞組模型、11 種排列 | 有：字鍵先原樣顯示，直到構成完整有調音節才轉換 | 個人詞庫加權 | 無，離線 | 0.2 MB `.deb`（僅引擎） | GPL-3.0 |
| [ChiaKey](https://github.com/chiakich/ChiaKey) | macOS（穩定）、Windows（預覽）、iOS（實驗核心） | Yahoo KeyKey 系列、bigram；另有倉頡、速成、`.cin` | 僅限注音自然相容之字元 | 記錄選字；可匯入 KeyKey 詞庫 | 未說明 | macOS `.pkg` 50.2 MB | BSD-3-Clause |
| [Bopomix](https://github.com/lmanchu/bopomix) | macOS 13+、Apple Silicon | 小麥注音引擎分支（Swift）、僅大千 | 有：無法構成音節之字母直接視為英文；支援 Tab 補完英文 | 本機學習英文詞 | 無；句級 AI 重排研究中，尚未實裝 | `.dmg` 6.6 MB | MIT |
| [KeyKey（琦琦）](https://github.com/polobread/KeyKey/releases) | macOS、Windows、Linux（fcitx5）、iOS、Android | Yahoo 2012 程式碼、30 組領域詞庫；另有倉頡 | 未宣稱 | 智慧詞組組字與學習 | 標明不存取網路 | macOS `.pkg.zip` 38.2 MB | 混合授權：Yahoo 原始碼 BSD-3-Clause、各平台前端 MIT；v1.3.1（2026-10-02） |
| [ZingIME（晶晶）](https://zingime.com/) | macOS、Apple Silicon | 注音、40 萬以上詞彙 | 有（主打功能）：同一模式可直接輸入中英，支援 Tab 補完英文 | 未說明 | 裝置端模型選字，不依賴雲端（待核實） | `.dmg` 271.6 MiB | 商用付費、提供 14 天試用（待核實） |
| [唯音（vChewing）](https://github.com/vChewing/vChewing-macOS) | macOS 12+（Aqua 紀念版支援 10.9 起） | 鐵恨注音並擊引擎；注音排列與拼音種類數量眾多；簡繁語料庫分離 | 有：中英文混合輸入回退模式（注音鍵先試成讀音，不成則回退英文）；v4.8.6 起 ASCII 顯示於組字區 | 漸退記憶（POM）觀察選字並參與組句；使用者片語、自訂關聯詞語 | 未說明；啟用 Sandbox | 12.6 MB `.pkg`（v4.8.6，2026-09-29） | MulanPSL-2.0（核心模組 LGPLv3）；修改後不得沿用產品名稱 |
| [小麥注音（McBopomofo）](https://github.com/openvanilla/McBopomofo) | macOS 13+；Windows（win-mcbopomofo）、Linux（fcitx5-mcbopomofo）、網頁／ChromeOS 為同組織獨立儲存庫 | Gramambular 2 組句、僅 Unigram 語言模型、大千 | 未宣稱 | 記錄使用者選字覆寫；使用者詞彙與排除詞彙 | 未說明 | 5.3 MB `.zip`（v3.1.1，2026-09-02） | MIT |
| [Rime（鼠鬚管／小狼毫／中州韻）](https://rime.im) | macOS（鼠鬚管）、Windows（小狼毫）、Linux（ibus／fcitx-rime） | librime 方案制引擎；注音為 rime-bopomofo 方案（大千、動態能力佈局，詞庫依賴 terra_pinyin），另有倉頡、速成等方案 | 需切換中英模式（注音方案內建 `ascii_mode` 開關） | librime 內建使用者詞典（`user_dictionary`） | 無，離線 | 鼠鬚管 25.5 MB `.pkg`（1.1.2）；小狼毫 12.4 MB `.exe`（0.17.4） | GPL-3.0（鼠鬚管、小狼毫）；librime BSD-3-Clause |
| **Misstype（本專案）** | macOS IMK、Linux fcitx5 | 小麥注音詞庫、大千、Swift `MisstypeCore` | 有，`mixedEnglish`（macOS 預設關閉） | 學習＋使用者詞庫 | 預設無；可選 Jev LLM 輔助（需明確啟用） | `.dmg` 4.4 MB（v0.0.1，通用版本） | MIT |

## 技術功能矩陣

`Y`＝專案明確說明；`-`＝未找到說明；`n/a`＝不適用。

| 能力 | Ari | ChiaKey | Bopomix | KeyKey | ZingIME | 唯音 | 小麥 | Rime | Misstype |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 注音 | Y | Y | Y（大千） | Y | Y | Y | Y（大千） | Y（方案） | Y（大千） |
| 其他排列（Eten、許氏、Dvorak…） | Y（11） | - | - | - | - | Y（最多） | - | - | - |
| 倉頡／速成／`.cin` | - | Y | - | 倉頡 | - | - | - | Y（倉頡、速成方案） | - |
| 句級詞組模型 | libchewing | bigram | 小麥注音 | Y | 「AI」 | Y（Megrez／Homa） | Y（Unigram） | 方案而異 | 詞庫 DP＋學習 |
| 可省略聲調 | - | - | - | - | - | 部分（注音狂打：自動切音節、只打聲母；預設停用） | - | Y（方案說明：可省略聲調、韻母） | Y |
| 編輯容錯（顛倒、鄰鍵、插入／刪除） | 部分（順序、重複／無效鍵） | - | - | - | - | - | - | 部分（方案：`free_order` 音節內順序、`abbrev` 只打聲母；引擎另有預設關閉的 `enable_correction`，見下節） | Y |
| 觸控／座標模糊比對 | - | - | - | - | - | - | - | - | 核心 v1，尚未接觸控面 |
| 中英混輸、免切換 | Y | - | Y | - | Y | Y（中英混合輸入回退模式；ASCII 顯示於組字區） | - | -（需切換；雾凇／白霜的拼音方案可掛英文詞庫，見下節） | Y（v1） |
| 英文拼字修復 | - | - | - | - | - | - | - | - | Y |
| 英文完成（Tab） | - | - | Y | - | Y | - | - | - | - |
| 英文詞學習 | - | - | Y | - | - | - | - | - | - |
| 個人學習 | Y | Y | Y | Y（選字覆寫＋相鄰詞；可重設） | - | Y（POM） | Y（選字覆寫） | Y（使用者詞典） | Y |
| 使用者詞庫編輯器 | - | Y（匯入） | - | Y（詞彙編輯器；選單直達「編輯自訂詞…」） | - | Y（片語整理） | Y（使用者詞彙） | - | Y（Shift+←/→、設定） |
| 就地加詞／刪詞手勢（組字中） | - | - | - | Shift+方向鍵選取，Enter 加入（審查文件稱原始碼保留，現行版本未驗證） | - | Y（Shift+←/→ 標記；Enter 加權；Shift+Cmd+Enter 降權；Backspace/Delete 濾除） | - | 僅刪候選（Shift+Delete，預設 Ctrl+K）；未找到加詞手勢 | Y（Shift+←/→ 標記，Return 加入／再按移除） |
| 音節游標／組字區內重選 | Y | - | - | - | - | - | - | - | Y |
| 已送出文字重新轉換 | Y（Control+Alt+R） | - | - | - | - | - | - | - | - |
| 組字時分段自動送出 | - | - | - | - | - | - | - | - | Y |
| 保留／可重放原始軌跡 | - | - | - | - | - | - | - | - | Y（捕捉端） |
| 簡繁切換 | - | - | - | - | - | Y（語料庫分離） | - | Y（OpenCC 濾鏡：簡化、港、臺字形） | - |
| 預設離線 | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| LLM／模型輔助 | - | - | 研究中 | - | 裝置端 | - | - | - | 可選、需明確啟用（Jev） |
| macOS | - | Y | Y | Y | Y | Y | Y | Y（鼠鬚管） | Y |
| Windows | - | 預覽 | - | Y | - | - | Y（獨立專案） | Y（小狼毫） | - |
| Linux | Y（fcitx5） | - | - | Y（fcitx5） | - | - | Y（fcitx5，獨立專案） | Y | Y（fcitx5） |
| iOS／Android | - | iOS（實驗） | - | Y／Y | - | - | - | - | - |
| 跨平台核心 | WASM | - | - | - | - | LibVanguard（獨立引擎儲存庫） | - | librime | C ABI＋Swift 核心 |
| 測試與驗證 | sanitizer、fuzz、coverage | - | - | - | - | - | - | - | C1–C13、一致性與掃描 |
| 授權 | GPL-3.0 | BSD-3 | MIT | BSD-3＋MIT | 專有（未找到原始碼；GitHub 搜尋無相符儲存庫） | MulanPSL-2.0／LGPLv3 | MIT | GPL-3.0／BSD-3 | 見儲存庫 |

詳細的專案分析、下載大小與「值得評估的功能」保留在[英文研究頁](competitors-en.md)；組詞演算法與各家解碼引擎之深度比較見[組詞與解碼引擎技術研究](decoding-engines.md)。

## Rime 其他方案深入研究（2026-10-04）

來源：`rime/librime` 原始碼、`rime/*` 各方案儲存庫、雾凇拼音（rime-ice，GPL-3.0）、白霜拼音（rime-frost，GPL-3.0）。以下都是讀檔案得到的，沒有安裝或實測。

- **引擎內建打字修正，但預設關閉。** `librime` 的 `src/rime/dict/corrector.cc` 實作方案層級的 `translator/enable_correction`：編輯距離（刪除、插入各算 2，相鄰兩鍵顛倒算 2）、鄰鍵替換（QWERTY 相鄰鍵算 1，其餘算 4）、修正結果的可信度固定為 log(0.01)，單次最多 4 處修正。我逐檔查了 `rime-bopomofo`、`rime-luna-pinyin`、`rime-terra-pinyin`、`rime-double-pinyin`、`rime-prelude`、`rime-cangjie`、`rime-quick`、`rime-combo-pinyin`、`rime-pinyin-simp`、`rime-jyutping`、`rime-cantonese`，以及雾凇、白霜的所有方案檔，沒有任何一個設為 `true`。librime 的 issue 有人回報「疑似發生自動糾錯」「自動糾錯權重過高」（#1195、#1120），推測是使用者或第三方設定自行開啟（只讀了標題，未讀內容）。所以 Rime 技術上有鄰鍵／顛倒／插入刪除修正，但官方注音方案沒有用它。
- **鄰鍵表只是 QWERTY 字母列與數字列的左右相鄰**，沒有上下列、沒有觸控座標；注音方案的拼寫已轉成大千鍵位，是否合適未驗證。
- **拼音方案的模糊音是寫死的規則，不是依輸入證據計分。** 地球拼音（`terra_pinyin`）有 `derive` 規則，例如 `ao`→`oa`、`ng`→`gn`（順序）、省略聲調、只打首字母；雾凇拼音的 zh/z、l/n、f/h 等模糊音是註解掉的範本，需自行啟用。
- **中英混打走次要翻譯器，不是自由交錯。** 雾凇、白霜把 `melt_eng`（英文詞庫，白霜的說明為「只包含少量常用詞彙」）當第二個 `table_translator` 掛在拼音方案上，英文詞以候選出現；另有 Lua `cn_en_spacer` 為「中英混輸詞條」補空格、`autocap_filter` 自動大寫。這些都只在拼音方案裡，白霜的 `bopomofo*.schema.yaml` 沒有掛。
- **白霜另附注音方案**（`bopomofo`、`bopomofo_express`、`bopomofo_tw`），與官方版同源，未見額外容錯。
- **句子層級語言模型是外掛。** 八股文（`rime-essay`）是共用詞彙與詞頻；`librime-octagram`（BSD-3-Clause）是語法（n-gram）外掛。第三方評測 `gaboolic/rime-schema-compare`（程式與語料開源，報告 2026-08-30，簡體知乎熱榜 3466 句）中，白霜 61.19% 整句正確、加語法後 65.87%；雾凇 53.29%／59.09%；朙月拼音 47.49%（加語法反而 40.33%）。這是簡體拼音的結果，**不能直接比較注音，也不是本專案的測量**。
- **行動端有 Rime 移植**：同文（Trime，GPL-3.0）、fcitx5-android（LGPL-2.1）、Hamster（iOS，MIT，最後更新 2025-05）。我只看了儲存庫說明，沒有查它們是否傳遞觸控座標給引擎，所以「觸控座標模糊比對」仍標 `-`。
- **使用者詞典**：librime 的 `user_dictionary`／`user_db` 提供學習；注音方案另有 `custom_phrase`（固定表，不會學習）。

## 長期定位

**起點：** 本專案從「無固定位置的按鍵輸入」出發——連眼睛都不想睜開的連續輸入，由解碼器大致還原成想打的字；同時也是一次「LLM 時代的自製」實驗：連輸入法這種成熟領域的東西，也能自己維護。因此下表與下列比較是設計參照，不是功能數量的競賽。

[唯音（vChewing，原威注音）](https://github.com/vChewing/vChewing-macOS) 作為專案長期推薦與比對的基準：它是成熟且高度可日常使用的注音輸入法，適合用來對照相容性、候選字流程與穩定度。Misstype 無意涵蓋其完整的龐大功能面，而是專注驗證兩個差異化核心：

- **中英混打學習：** 在同一輸入狀態下辨識中文、英文及常見英文拼寫錯誤，並將使用者的選字與詞庫學習納入後續解碼；以採納率、誤判率、延遲與學習後的準確度改善作為評估指標。
- **模糊輸入配對：** 將鍵盤編輯容錯與觸控座標證據配對至候選讀法，並保留完整原始軌跡，使鄰鍵、順序顛倒、漏鍵／多鍵與聲調容錯皆可重放與量測；以修復率、誤修率及候選干擾程度作為評估指標。

這兩項能力均以固定測試語句、真實去識別化輸入紀錄以及跨平台情境進行驗證，不以未經測量的功能宣稱為完成指標。

## 競品資料追蹤原則

本文件記錄的資訊為特定時間點的公開狀態，需定期校對維護。追蹤各競品時，建議記錄：專案網址、檢視日期、最新版本／釋出日期、平台支援、功能現況、安裝檔大小、來源連結，以及驗證狀態（已實測／官方宣稱／未提及）。

1. **版本與下載大小：** 以 GitHub Releases API 或官方下載頁為主；定期檢查更新，每次版本變更時重新測量安裝檔大小。
2. **功能變更追蹤：** 比對 README、CHANGELOG、release notes 與官方網站。新功能在未實測前標為「待驗證」，經乾淨環境手動測試後再調整為「已驗證」。
3. **客觀可重現測試：** 維持不含個資的固定測試語句集與操作腳本；僅在相同平台、輸入模式與版本下進行比較。缺乏客觀測量條件時，不填入推測性數值。
4. **來源留存與審查：** 表格內每項具體功能皆保留來源網址與查核日期；媒體報導僅作參考線索。定期複查並清理失效連結，過時資訊降級為「待核實」。
5. **後續涵蓋名單：** 依專案需求逐步將 Gboard 與系統原生注音納入相同矩陣進行對照（Rime、唯音、小麥注音已於 2026-10-04 加入）。

此追蹤流程旨在清楚區分「已實測驗證」與「文宣宣稱」，確保數據客觀具參考價值。

## 研究缺口

- ZingIME 的相關細節目前主要來自搜尋摘要與報導，待進一步核實官方最新資訊。
- Bopomix 的部分子頁面先前無法存取（404），聲調處理邏輯與未來路線圖待補齊。
- 尚未進行跨輸入法的同條件打字測量；延遲與準確度比較需待建立固定語句測試集與輸入軌跡後再行評估。
- Rime、唯音、小麥注音的資料取自其 README、LICENSE、`algorithm.md`、GitHub 組織儲存庫列表與 Releases API；Rime 取自 `rime-bopomofo` 方案檔與 librime 原始碼目錄。`-` 仍代表「未在這些來源找到」。Rime 的其他方案已另做一輪（見「Rime 其他方案深入研究」），社群方案只讀了雾凇與白霜；Windows／Linux 版小麥與唯音的其他平台版本只確認儲存庫存在，未查功能是否與 macOS 版一致。Gboard 與系統原生注音尚未涵蓋。
