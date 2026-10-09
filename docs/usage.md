# 打字操作指南

用注音鍵盤照常輸入，以下是游標、選字、詞庫等操作。安裝見 [README](../README.md#安裝)。

* **連續鍵入與免聲調**：聲調可選擇性鍵入；打字時邊打邊即時轉換，僅當前尚未拼完的注音符號會保留在組字區內。鍵入聲調鍵會立即完成該音節，<kbd>Space</kbd>（空白鍵）也代表第一聲（陰平）。
* **遞交輸入與注音文**：按下 <kbd>Enter</kbd> 鍵會直接遞交當前畫面上顯示的文字（包含尚未拼完的注音符號，支援注音文）；按下 <kbd>Shift</kbd> + <kbd>Enter</kbd> 則會將原始鍵入的注音符號直接輸出。
* **候選字選字模式**：按下 <kbd>↓</kbd> 或 <kbd>Tab</kbd>（亦可按 <kbd>←</kbd> 倒退至前方的詞彙）即可進入選字選單。選字時可使用鍵盤中間一排的 <kbd>asdfghjk</kbd> 快速鍵選取候選字（可在偏好設定調整；平常打字時這些鍵仍是正常的注音按鍵）。<kbd>Tab</kbd>／<kbd>Shift</kbd> + <kbd>Tab</kbd> 翻頁。按 <kbd>Esc</kbd> 退出選字模式；在一般打字狀態下按 <kbd>Esc</kbd> 則清空整個組字區。
* **全形符號與中英切換**：<kbd>Shift</kbd> + <kbd>數字鍵</kbd> 與 <kbd>Shift</kbd> + <kbd>=</kbd>、<kbd>[</kbd>、<kbd>]</kbd>、<kbd>&#96;</kbd> 可直接鍵入全形符號（！＠＃＄％︿＆＊（）＋｛｝～）。<kbd>Backspace</kbd> 可倒退修改原始組字內容。輕按單次 <kbd>Shift</kbd> 或按下 <kbd>Shift</kbd> + <kbd>Space</kbd> 即可直接遞交並切換中／英文模式。
* **我的詞庫**：打字時用 <kbd>Shift</kbd> + <kbd>←</kbd>/<kbd>→</kbd> 標記已轉換文字中的音節，按 <kbd>Return</kbd> 即可把詞（人名、專有名詞）加入自己的詞庫；對同一段標記再按 <kbd>Return</kbd> 則移除。macOS 的「設定 → 我的詞庫」是同一份 `user_dictionary.tsv` 的純文字編輯器，格式與唯音的 userdata 相同（`詞語 注音`，每行一筆），可直接貼上或用「匯入…」讀入唯音詞庫；只有一般詞彙清單時，可用 Will 保哥的第三方[線上產生器](https://vu.gh.miniasp.com/)（[原始碼](https://github.com/doggy8088/vChewing-userdata-generator)，MIT；與本專案無關）轉成此格式；Linux 請直接編輯 `~/.local/share/misstype/user_dictionary.tsv`。
* **在地化學習**：系統會在本地記憶各詞彙的選字偏好，單個漢字則會結合其前置上下文詞彙共同學習與加權。
