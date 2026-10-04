import time
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
    decoder_version = "0.3"

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
        self._by_length: dict[int, list[tuple[tuple[str, ...], str]]] = {}
        for key, value in self.phrases.items():
            symbols = tuple(key.split())
            self._by_length.setdefault(len(symbols), []).append((symbols, value))

    def decode(self, tokens: Sequence[PhoneticToken],
               context: DecodeContext | None = None) -> DecodeResult:
        revision = context.revision if context is not None else 0
        started = time.perf_counter_ns()
        rendered: list[str] = []
        alignment: list[tuple[str, str]] = []
        current: list[tuple[str, ...]] = []
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

    def _flush(self, current: list[tuple[str, ...]], rendered: list[str], alignment: list[tuple[str, str]]) -> bool:
        """Flush one phrase run; return True when tones were inferred."""
        if not current:
            return False
        key = " ".join(item[0] for item in current)
        value, inferred = self._lookup(current, key)
        rendered.append(value)
        alignment.append((key, value))
        current.clear()
        return inferred

    def _lookup(self, current: list[tuple[str, ...]], primary: str) -> tuple[str, bool]:
        """Return (text, tone_inferred). Tones are optional hints: an exact
        match wins, a unique toneless match commits at reduced confidence,
        and an ambiguous toneless match stays a visible bracket fallback."""
        if primary in self.phrases:
            return self.phrases[primary], False
        # Scan only same-length dictionary entries, never the Cartesian
        # product of input alternatives. Cost is O(tokens * candidates +
        # same-length dictionary entries * tokens), even for unknown input.
        # Lexicographic position ranks preserve the previous exact-tone
        # preference. These ranks are not calibrated language probabilities.
        for infer_tones in (False, True):
            ranks = []
            for choices in current:
                positions: dict[str, int] = {}
                for index, symbol in enumerate(choices):
                    positions.setdefault(strip_tone(symbol) if infer_tones else symbol, index)
                ranks.append(positions)
            matches: list[tuple[tuple[int, ...], str]] = []
            for symbols, text in self._by_length.get(len(current), ()):
                rank = []
                for symbol, positions in zip(symbols, ranks):
                    position = positions.get(strip_tone(symbol) if infer_tones else symbol)
                    if position is None:
                        break
                    rank.append(position)
                else:
                    matches.append((tuple(rank), text))
            if matches:
                best_rank = min(rank for rank, _ in matches)
                texts = {text for rank, text in matches if rank == best_rank}
                if len(texts) == 1:
                    return next(iter(texts)), infer_tones
                # Equal-ranked toneless homophones remain unresolved.
                break
        return "[" + primary + "]", False
