"""Standard Zhuyin keyboard key mapping used by the M1 keyboard adapter."""

# Taiwan Zhuyin layout, represented by physical US keyboard key labels.
KEY_TO_ZHUYIN = {
    "1": "ㄅ", "q": "ㄆ", "a": "ㄇ", "z": "ㄈ",
    "2": "ㄉ", "w": "ㄊ", "s": "ㄋ", "x": "ㄌ",
    "e": "ㄍ", "d": "ㄎ", "c": "ㄏ", "r": "ㄐ", "f": "ㄑ", "v": "ㄒ",
    "5": "ㄓ", "t": "ㄔ", "g": "ㄕ", "b": "ㄖ",
    "y": "ㄗ", "h": "ㄘ", "n": "ㄙ",
    "u": "ㄧ", "j": "ㄨ", "m": "ㄩ",
    "8": "ㄚ", "i": "ㄛ", "k": "ㄜ", ",": "ㄝ",
    "9": "ㄞ", "o": "ㄟ", "l": "ㄠ", ".": "ㄡ",
    "0": "ㄢ", "p": "ㄣ", ";": "ㄤ", "/": "ㄥ",
    "-": "ㄦ",
}

TONE_KEYS = {"3": "ˇ", "4": "ˋ", "6": "ˊ", "7": "˙", "SPACE": "˙"}


def key_to_token(code: str) -> tuple[str, str] | None:
    """Return (kind, value) for a physical key, or None if it is not phonetic."""
    if code.startswith("BPMF:"):
        key = code[5:]
        if key in KEY_TO_ZHUYIN:
            return "zhuyin", KEY_TO_ZHUYIN[key]
        if key in TONE_KEYS:
            return "tone", TONE_KEYS[key]
    return None
