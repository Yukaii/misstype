from dataclasses import dataclass
from math import hypot

from .fuzzy import KEY_NEIGHBORS
from .phonetic import KEY_TO_ZHUYIN
from .models import RawEvent


# A compact split-friendly layout in normalized surface coordinates.
LEFT_KEYS = {"1": (0.15, 0.20), "q": (0.30, 0.20), "a": (0.30, 0.50), "z": (0.30, 0.80),
             "2": (0.50, 0.20), "w": (0.50, 0.50), "s": (0.50, 0.80)}
RIGHT_KEYS = {"8": (0.15, 0.20), "i": (0.30, 0.20), "k": (0.30, 0.50), ",": (0.30, 0.80),
              "9": (0.50, 0.20), "o": (0.50, 0.50), "l": (0.50, 0.80)}


@dataclass(frozen=True)
class TouchHypothesis:
    key: str
    confidence: float
    alternatives: tuple[tuple[str, float], ...]

    @property
    def code(self) -> str:
        return f"BPMF_FUZZY:{self.key}"


def nearest_key(surface: str, x: float, y: float) -> TouchHypothesis:
    """Map normalized coordinates to a key and neighboring alternatives."""
    layout = LEFT_KEYS if surface == "left" else RIGHT_KEYS
    if not 0 <= x <= 1 or not 0 <= y <= 1:
        raise ValueError("touch coordinates must be normalized to [0, 1]")
    ranked = sorted(((hypot(x - px, y - py), key) for key, (px, py) in layout.items()))
    distance, key = ranked[0]
    confidence = max(0.1, 1.0 - distance * 1.5)
    alternatives = []
    for alt in KEY_NEIGHBORS.get(key, ()):
        if alt in KEY_TO_ZHUYIN:
            alternatives.append((alt, max(0.1, confidence - 0.2)))
    return TouchHypothesis(key, confidence, tuple(alternatives))


def touch_event(session_id: str, sequence: int, timestamp_ns: int,
                surface: str, x: float, y: float) -> RawEvent:
    """Create a replayable raw event from one normalized touch point."""
    hypothesis = nearest_key(surface, x, y)
    return RawEvent(session_id, sequence, timestamp_ns, surface, "touch_down",
                    code=hypothesis.code,
                    payload={"x": x, "y": y, "confidence": hypothesis.confidence})
