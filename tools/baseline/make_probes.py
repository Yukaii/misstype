"""Build the shared probe set for cross-IME comparison (probes.tsv).

Each probe is a short everyday sentence with its Zhuyin written by hand and
converted to Dachen keystrokes with the repo's own key map. The sentences
avoid neutral-tone words and 一/不 tone sandhi, where lexicons legitimately
disagree. A probe is only valid if every IME under test decodes its CLEAN
keystrokes to the expected text; run_clean_check flags the rest.

Usage: PYTHONPATH=src python tools/baseline/make_probes.py > tools/baseline/probes.tsv
"""
import sys
from misstype.phonetic import KEY_TO_ZHUYIN, TONE_KEYS

ZHUYIN_TO_KEY = {v: k for k, v in KEY_TO_ZHUYIN.items()}
TONE_TO_KEY = {"ˇ": "3", "ˋ": "4", "ˊ": "6"}  # first tone = space

SENTENCES = [
    ("ni-hao", "你好", "ㄋㄧˇ ㄏㄠˇ"),
    ("zao-shang-hao", "早上好", "ㄗㄠˇ ㄕㄤˋ ㄏㄠˇ"),
    ("wo-shi-xue-sheng", "我是學生", "ㄨㄛˇ ㄕˋ ㄒㄩㄝˊ ㄕㄥ"),
    ("dada", "測試一下會不會打對", None),  # legacy probe, keys given below
    ("weather", "今天天氣很好", "ㄐㄧㄣ ㄊㄧㄢ ㄊㄧㄢ ㄑㄧˋ ㄏㄣˇ ㄏㄠˇ"),
    ("library", "我想去圖書館", "ㄨㄛˇ ㄒㄧㄤˇ ㄑㄩˋ ㄊㄨˊ ㄕㄨ ㄍㄨㄢˇ"),
    ("station", "請問火車站在哪裡", "ㄑㄧㄥˇ ㄨㄣˋ ㄏㄨㄛˇ ㄔㄜ ㄓㄢˋ ㄗㄞˋ ㄋㄚˇ ㄌㄧˇ"),
    ("meeting", "明天早上九點開會", "ㄇㄧㄥˊ ㄊㄧㄢ ㄗㄠˇ ㄕㄤˋ ㄐㄧㄡˇ ㄉㄧㄢˇ ㄎㄞ ㄏㄨㄟˋ"),
    ("movie", "這個週末一起去看電影", "ㄓㄜˋ ㄍㄜˋ ㄓㄡ ㄇㄛˋ ㄧˋ ㄑㄧˇ ㄑㄩˋ ㄎㄢˋ ㄉㄧㄢˋ ㄧㄥˇ"),
    ("thanks", "謝謝你幫忙", "ㄒㄧㄝˋ ㄒㄧㄝˋ ㄋㄧˇ ㄅㄤ ㄇㄤˊ"),
    ("coffee", "我喜歡喝咖啡", "ㄨㄛˇ ㄒㄧˇ ㄏㄨㄢ ㄏㄜ ㄎㄚ ㄈㄟ"),
    ("mrt", "台北捷運很方便", "ㄊㄞˊ ㄅㄟˇ ㄐㄧㄝˊ ㄩㄣˋ ㄏㄣˇ ㄈㄤ ㄅㄧㄢˋ"),
    ("dinner", "我們一起吃晚餐", "ㄨㄛˇ ㄇㄣˊ ㄧˋ ㄑㄧˇ ㄔ ㄨㄢˇ ㄘㄢ"),
    ("report", "這份報告明天要交", "ㄓㄜˋ ㄈㄣˋ ㄅㄠˋ ㄍㄠˋ ㄇㄧㄥˊ ㄊㄧㄢ ㄧㄠˋ ㄐㄧㄠ"),
    ("ime", "輸入法可以學習使用者習慣", "ㄕㄨ ㄖㄨˋ ㄈㄚˇ ㄎㄜˇ ㄧˇ ㄒㄩㄝˊ ㄒㄧˊ ㄕˇ ㄩㄥˋ ㄓㄜˇ ㄒㄧˊ ㄍㄨㄢˋ"),
    ("typing", "打字速度越來越快", "ㄉㄚˇ ㄗˋ ㄙㄨˋ ㄉㄨˋ ㄩㄝˋ ㄌㄞˊ ㄩㄝˋ ㄎㄨㄞˋ"),
    ("breakfast", "我今天沒有吃早餐", "ㄨㄛˇ ㄐㄧㄣ ㄊㄧㄢ ㄇㄟˊ ㄧㄡˇ ㄔ ㄗㄠˇ ㄘㄢ"),
    ("noodles", "這家餐廳牛肉麵很好吃", "ㄓㄜˋ ㄐㄧㄚ ㄘㄢ ㄊㄧㄥ ㄋㄧㄡˊ ㄖㄡˋ ㄇㄧㄢˋ ㄏㄣˇ ㄏㄠˇ ㄔ"),
    ("friday", "週五晚上有空", "ㄓㄡ ㄨˇ ㄨㄢˇ ㄕㄤˋ ㄧㄡˇ ㄎㄨㄥˋ"),
    ("coding", "我正在學習寫程式", "ㄨㄛˇ ㄓㄥˋ ㄗㄞˋ ㄒㄩㄝˊ ㄒㄧˊ ㄒㄧㄝˇ ㄔㄥˊ ㄕˋ"),
    ("japan", "下個月要去日本旅行", "ㄒㄧㄚˋ ㄍㄜˋ ㄩㄝˋ ㄧㄠˋ ㄑㄩˋ ㄖˋ ㄅㄣˇ ㄌㄩˇ ㄒㄧㄥˊ"),
    ("window", "請把窗戶關起來", "ㄑㄧㄥˇ ㄅㄚˇ ㄔㄨㄤ ㄏㄨˋ ㄍㄨㄢ ㄑㄧˇ ㄌㄞˊ"),
    ("aircon", "天氣太熱所以開冷氣", "ㄊㄧㄢ ㄑㄧˋ ㄊㄞˋ ㄖㄜˋ ㄙㄨㄛˇ ㄧˇ ㄎㄞ ㄌㄥˇ ㄑㄧˋ"),
    ("late", "他昨天很晚才睡", "ㄊㄚ ㄗㄨㄛˊ ㄊㄧㄢ ㄏㄣˇ ㄨㄢˇ ㄘㄞˊ ㄕㄨㄟˋ"),
    ("book", "這本書非常有趣", "ㄓㄜˋ ㄅㄣˇ ㄕㄨ ㄈㄟ ㄔㄤˊ ㄧㄡˇ ㄑㄩˋ"),
    ("policy", "政府宣布新政策", "ㄓㄥˋ ㄈㄨˇ ㄒㄩㄢ ㄅㄨˋ ㄒㄧㄣ ㄓㄥˋ ㄘㄜˋ"),
    ("economy", "經濟成長速度放慢", "ㄐㄧㄥ ㄐㄧˋ ㄔㄥˊ ㄓㄤˇ ㄙㄨˋ ㄉㄨˋ ㄈㄤˋ ㄇㄢˋ"),
    ("prepare", "請在會議前準備好資料", "ㄑㄧㄥˇ ㄗㄞˋ ㄏㄨㄟˋ ㄧˋ ㄑㄧㄢˊ ㄓㄨㄣˇ ㄅㄟˋ ㄏㄠˇ ㄗ ㄌㄧㄠˋ"),
    ("rain", "週末天氣預報會下雨", "ㄓㄡ ㄇㄛˋ ㄊㄧㄢ ㄑㄧˋ ㄩˋ ㄅㄠˋ ㄏㄨㄟˋ ㄒㄧㄚˋ ㄩˇ"),
    ("crash", "電腦突然當機", "ㄉㄧㄢˋ ㄋㄠˇ ㄊㄨ ㄖㄢˊ ㄉㄤ ㄐㄧ"),
    ("park", "小朋友在公園玩耍", "ㄒㄧㄠˇ ㄆㄥˊ ㄧㄡˇ ㄗㄞˋ ㄍㄨㄥ ㄩㄢˊ ㄨㄢˊ ㄕㄨㄚˇ"),
    ("work", "他很努力工作", "ㄊㄚ ㄏㄣˇ ㄋㄨˇ ㄌㄧˋ ㄍㄨㄥ ㄗㄨㄛˋ"),
    ("booking", "請幫我預訂會議室", "ㄑㄧㄥˇ ㄅㄤ ㄨㄛˇ ㄩˋ ㄉㄧㄥˋ ㄏㄨㄟˋ ㄧˋ ㄕˋ"),
    ("discuss", "這個問題需要仔細討論", "ㄓㄜˋ ㄍㄜˋ ㄨㄣˋ ㄊㄧˊ ㄒㄩ ㄧㄠˋ ㄗˇ ㄒㄧˋ ㄊㄠˇ ㄌㄨㄣˋ"),
    ("market", "我昨天去超市買菜", "ㄨㄛˇ ㄗㄨㄛˊ ㄊㄧㄢ ㄑㄩˋ ㄔㄠ ㄕˋ ㄇㄞˇ ㄘㄞˋ"),
    ("beach", "夏天海邊人很多", "ㄒㄧㄚˋ ㄊㄧㄢ ㄏㄞˇ ㄅㄧㄢ ㄖㄣˊ ㄏㄣˇ ㄉㄨㄛ"),
    ("boss", "老闆決定提早下班", "ㄌㄠˇ ㄅㄢˇ ㄐㄩㄝˊ ㄉㄧㄥˋ ㄊㄧˊ ㄗㄠˇ ㄒㄧㄚˋ ㄅㄢ"),
    ("phone", "手機快沒電", "ㄕㄡˇ ㄐㄧ ㄎㄨㄞˋ ㄇㄟˊ ㄉㄧㄢˋ"),
    ("number", "請告訴我電話號碼", "ㄑㄧㄥˇ ㄍㄠˋ ㄙㄨˋ ㄨㄛˇ ㄉㄧㄢˋ ㄏㄨㄚˋ ㄏㄠˋ ㄇㄚˇ"),
    ("quiet", "圖書館禁止大聲說話", "ㄊㄨˊ ㄕㄨ ㄍㄨㄢˇ ㄐㄧㄣˋ ㄓˇ ㄉㄚˋ ㄕㄥ ㄕㄨㄛ ㄏㄨㄚˋ"),
    ("jog", "週日早上去公園跑步", "ㄓㄡ ㄖˋ ㄗㄠˇ ㄕㄤˋ ㄑㄩˋ ㄍㄨㄥ ㄩㄢˊ ㄆㄠˇ ㄅㄨˋ"),
    ("winter", "今年冬天特別冷", "ㄐㄧㄣ ㄋㄧㄢˊ ㄉㄨㄥ ㄊㄧㄢ ㄊㄜˋ ㄅㄧㄝˊ ㄌㄥˇ"),
]
LEGACY_KEYS = {"dada": "hk4g4u6vu84cjo41j6cjo42832jo4"}


def to_keys(zhuyin: str) -> str:
    out = []
    for syl in zhuyin.split():
        tone = " "
        body = syl
        if syl[-1] in TONE_TO_KEY:
            tone, body = TONE_TO_KEY[syl[-1]], syl[:-1]
        out.append("".join(ZHUYIN_TO_KEY[c] for c in body) + tone)
    return "".join(out)


def main() -> None:
    print("# name\tkeys\texpected\tsyllables")
    for name, text, zhuyin in SENTENCES:
        keys = LEGACY_KEYS[name] if zhuyin is None else to_keys(zhuyin)
        n = len(zhuyin.split()) if zhuyin else len(text)
        # keys may contain a literal space (first tone); TSV uses tabs, so keep it.
        print(f"{name}\t{keys}\t{text}\t{n}")


if __name__ == "__main__":
    sys.exit(main())
