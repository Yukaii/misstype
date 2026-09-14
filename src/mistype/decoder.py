import time
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
                current.append(token.value + (token.tone or ""))
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
        key = " ".join(current)
        value = self.phrases.get(key, "[" + key + "]")
        rendered.append(value)
        alignment.append((key, value))
        current.clear()
