import time
from itertools import product
from collections.abc import Sequence

from .models import DecodeResult, PhoneticToken


class OfflineDecoder:
    """Small deterministic seam; replace its phrase table with a real model at M1/M4."""

    decoder_id = "offline-fixture"
    decoder_version = "0.1"

    phrases = {
        "ㄋ ㄧˇ ㄏ ㄠˇ": "你好",
        "ㄋ ㄧˇ": "你",
        "ㄨ ㄛˇ ㄕˋ ㄒ ㄩㄝˊ ㄕ ㄥ": "我是學生",
        "ㄓ ㄜˋ ㄕˋ ㄧㄡˇ ㄑ ㄩˋ ㄉ ㄜ˙ ㄕˋ ㄧ ㄢˋ": "這是有趣的實驗",
    }

    def decode(self, tokens: Sequence[PhoneticToken], revision: int = 0) -> DecodeResult:
        started = time.perf_counter_ns()
        rendered: list[str] = []
        alignment: list[tuple[str, str]] = []
        current: list[str] = []
        for token in tokens:
            if token.kind == "boundary":
                if token.value == "enter":
                    self._flush(current, rendered, alignment)
                    rendered.append("\n")
                # SPACE is a phonetic syllable separator during capture. Keep
                # collecting until a non-Zhuyin token or explicit commit.
            elif token.kind == "zhuyin":
                primary = token.value + (token.tone or "")
                current.append((primary,) + tuple(value + (token.tone or "") for value, _ in token.alternatives))
            else:
                self._flush(current, rendered, alignment)
                rendered.append(token.value)
        self._flush(current, rendered, alignment)
        elapsed = (time.perf_counter_ns() - started) / 1_000_000
        return DecodeResult(revision, "".join(rendered), 1.0, self.decoder_id,
                            self.decoder_version, elapsed, tuple(alignment))

    def _flush(self, current: list[str], rendered: list[str], alignment: list[tuple[str, str]]) -> None:
        if not current:
            return
        key = " ".join(item[0] if isinstance(item, tuple) else item for item in current)
        value = self._lookup(current, key)
        rendered.append(value)
        alignment.append((key, value))
        current.clear()

    def _lookup(self, current: list[str], primary: str) -> str:
        if primary in self.phrases:
            return self.phrases[primary]
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
                return self.phrases[phrase]
        return "[" + primary + "]"
