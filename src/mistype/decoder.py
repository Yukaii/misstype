import time
from itertools import product
from collections.abc import Sequence

from .models import DecodeContext, DecodeResult, PhoneticToken


TONE_MARKS = "ˊˇˋ˙"

# Confidence for a phrase reconstructed without tone evidence. Exact-tone
# matches keep 1.0; tone-inferred matches report lower confidence so the UI
# and metrics can distinguish "typed with tones" from "tones guessed".
TONE_INFERRED_CONFIDENCE = 0.6


def strip_tone(key: str) -> str:
    """Remove tone marks from a space-joined phonetic key."""
    return "".join(char for char in key if char not in TONE_MARKS)


class OfflineDecoder:
    """Small deterministic seam; replace its phrase table with a real model at M1/M4."""

    decoder_id = "offline-fixture"
    decoder_version = "0.2"

    phrases = {
        "ㄋ ㄧˇ ㄏ ㄠˇ": "你好",
        "ㄋ ㄧˇ": "你",
        "ㄋ ㄧˇ ㄏ ㄠˇ ㄇ ㄚ˙": "你好嗎",
        "ㄨ ㄛˇ ㄕˋ ㄒ ㄩ ㄝˊ ㄕ ㄥ": "我是學生",
        "ㄓ ㄜˋ ㄕˋ ㄧ ㄡˇ ㄑ ㄩˋ ㄉ ㄜ˙ ㄕˊ ㄧ ㄢˋ": "這是有趣的實驗",
        "ㄒ ㄧ ㄝˋ ㄒ ㄧ ㄝ˙": "謝謝",
        "ㄉ ㄨ ㄟˋ ㄅ ㄨˋ ㄑ ㄧˇ": "對不起",
        "ㄏ ㄠˇ ㄉ ㄜ˙ ㄇ ㄚ˙": "好的嗎",
        "ㄗ ㄠˇ ㄕ ㄤˋ ㄏ ㄠˇ": "早上好",
    }

    def __init__(self) -> None:
        self._toneless_index: dict[str, list[tuple[str, str]]] = {}
        for key, value in self.phrases.items():
            self._toneless_index.setdefault(strip_tone(key), []).append((key, value))

    def decode(self, tokens: Sequence[PhoneticToken],
               context: DecodeContext | None = None) -> DecodeResult:
        revision = context.revision if context is not None else 0
        started = time.perf_counter_ns()
        rendered: list[str] = []
        alignment: list[tuple[str, str]] = []
        current: list[str] = []
        tone_inferred = False
        for token in tokens:
            if token.kind == "boundary":
                if token.value == "enter":
                    tone_inferred = self._flush(current, rendered, alignment) or tone_inferred
                    rendered.append("\n")
                # SPACE is a phonetic syllable separator during capture. Keep
                # collecting until a non-Zhuyin token or explicit commit.
            elif token.kind == "zhuyin":
                primary = token.value + (token.tone or "")
                current.append((primary,) + tuple(value + (token.tone or "") for value, _ in token.alternatives))
            else:
                tone_inferred = self._flush(current, rendered, alignment) or tone_inferred
                rendered.append(token.value)
        tone_inferred = self._flush(current, rendered, alignment) or tone_inferred
        elapsed = (time.perf_counter_ns() - started) / 1_000_000
        confidence = TONE_INFERRED_CONFIDENCE if tone_inferred else 1.0
        return DecodeResult(revision, "".join(rendered), confidence, self.decoder_id,
                            self.decoder_version, elapsed, tuple(alignment))

    def _flush(self, current: list[str], rendered: list[str], alignment: list[tuple[str, str]]) -> bool:
        """Flush one phrase run; return True when tones were inferred."""
        if not current:
            return False
        key = " ".join(item[0] if isinstance(item, tuple) else item for item in current)
        value, inferred = self._lookup(current, key)
        rendered.append(value)
        alignment.append((key, value))
        current.clear()
        return inferred

    def _lookup(self, current: list[str], primary: str) -> tuple[str, bool]:
        """Return (text, tone_inferred). Tones are optional hints: an exact
        match wins, a unique toneless match commits at reduced confidence,
        and an ambiguous toneless match stays a visible bracket fallback."""
        if primary in self.phrases:
            return self.phrases[primary], False
        # Search bounded alternatives. This is intentionally phrase-level:
        # fuzzy correction should use context, not silently rewrite each key.
        choices = []
        for item in current:
            if isinstance(item, tuple):
                choices.append(item)
            else:
                choices.append((item,))
        for candidate in product(*choices):
            phrase = " ".join(candidate)
            if phrase in self.phrases:
                return self.phrases[phrase], False
        toneless = self._toneless_index.get(strip_tone(primary), [])
        if len(toneless) == 1:
            return toneless[0][1], True
        return "[" + primary + "]", False
