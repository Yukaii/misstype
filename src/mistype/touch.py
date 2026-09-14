from dataclasses import dataclass
from math import hypot

from .fuzzy import KEY_NEIGHBORS
from .phonetic import KEY_TO_ZHUYIN, TONE_KEYS
from .models import RawEvent


# Full split layout, versioned for replay. Normalized [0, 1] per surface.
# The left surface owns the left-hand QWERTY columns plus tones 3/4;
# the right surface owns the right-hand columns plus tones 6/7.
# Legacy compact positions are preserved exactly so old traces replay.
LAYOUT_VERSION = "full-split-1"

LEFT_KEYS = {
    # Legacy compact positions (kept for replay compatibility).
    "1": (0.15, 0.20), "q": (0.30, 0.20), "a": (0.30, 0.50), "z": (0.30, 0.80),
    "2": (0.50, 0.20), "w": (0.50, 0.50), "s": (0.50, 0.80),
    # Number/tone row and QWERTY middle columns.
    "3": (0.70, 0.10), "4": (0.88, 0.10),
    "e": (0.70, 0.23), "r": (0.88, 0.23),
    "d": (0.70, 0.36), "f": (0.88, 0.36),
    "c": (0.70, 0.49), "v": (0.88, 0.49),
    "x": (0.70, 0.62), "g": (0.88, 0.62),
    "5": (0.70, 0.75), "b": (0.88, 0.75),
    "t": (0.70, 0.88),
}
RIGHT_KEYS = {
    # Legacy compact positions (kept for replay compatibility).
    "8": (0.15, 0.20), "i": (0.30, 0.20), "k": (0.30, 0.50), ",": (0.30, 0.80),
    "9": (0.50, 0.20), "o": (0.50, 0.50), "l": (0.50, 0.80),
    # Right-hand columns and tone keys.
    "6": (0.70, 0.10), "7": (0.88, 0.10),
    "y": (0.70, 0.23), "u": (0.88, 0.23),
    "h": (0.70, 0.36), "j": (0.88, 0.36),
    "n": (0.70, 0.49), "m": (0.88, 0.49),
    "0": (0.70, 0.62), "/": (0.88, 0.62),
    "p": (0.70, 0.75), ".": (0.88, 0.75),
    ";": (0.70, 0.88), "-": (0.88, 0.88),
}


@dataclass(frozen=True)
class TouchHypothesis:
    key: str
    confidence: float
    alternatives: tuple[tuple[str, float], ...]
    spatial: tuple[tuple[str, float], ...] = ()
    """Distance-ranked (key, weight) starting with the nearest key itself."""

    @property
    def code(self) -> str:
        # Tone keys have no fuzzy Zhuyin neighbors; emit them exactly so the
        # normalizer can attach the tone to the preceding symbol.
        if self.key in TONE_KEYS:
            return f"BPMF:{self.key}"
        return f"BPMF_FUZZY:{self.key}"


def layout_keys(surface: str) -> dict[str, tuple[float, float]]:
    """Return the key positions for one surface, for UI rendering and tests."""
    if surface == "left":
        return dict(LEFT_KEYS)
    if surface == "right":
        return dict(RIGHT_KEYS)
    raise ValueError("surface must be 'left' or 'right'")


def key_position(key: str) -> tuple[str, tuple[float, float]]:
    """Return (surface, (x, y)) for a physical key; raises KeyError if unknown."""
    if key in LEFT_KEYS:
        return "left", LEFT_KEYS[key]
    if key in RIGHT_KEYS:
        return "right", RIGHT_KEYS[key]
    raise KeyError(f"unknown touch key: {key!r}")


def _check_surface(surface: str) -> None:
    if surface not in ("left", "right"):
        raise ValueError("surface must be 'left' or 'right'")


def _check_coordinates(x: float, y: float) -> None:
    if not 0 <= x <= 1 or not 0 <= y <= 1:
        raise ValueError("touch coordinates must be normalized to [0, 1]")


# How many distance-ranked neighbors (beyond the nearest key itself) travel
# in the event payload for coordinate-aware decoding.
SPATIAL_NEIGHBOR_COUNT = 4


def _weight(distance: float) -> float:
    return max(0.1, 1.0 - distance * 1.5)


def payload_candidates(payload: object) -> tuple[tuple[str, float], ...]:
    """Extract spatial Zhuyin candidates from a touch payload.

    Returns () when the payload carries no usable neighbor ranking, so the
    caller falls back to keyboard neighborhoods (keyboard path, old traces).
    """
    if not isinstance(payload, dict):
        return ()
    neighbors = payload.get("neighbors")
    if not isinstance(neighbors, list):
        return ()
    candidates = []
    for entry in neighbors:
        if (isinstance(entry, (list, tuple)) and len(entry) == 2
                and isinstance(entry[0], str) and isinstance(entry[1], (int, float))):
            key, weight = entry
            if key in KEY_TO_ZHUYIN:
                candidates.append((KEY_TO_ZHUYIN[key], max(0.1, min(1.0, float(weight)))))
    return tuple(candidates)


def nearest_key(surface: str, x: float, y: float) -> TouchHypothesis:
    """Map normalized coordinates to a key and neighboring alternatives."""
    _check_surface(surface)
    _check_coordinates(x, y)
    layout = LEFT_KEYS if surface == "left" else RIGHT_KEYS
    ranked = sorted(((hypot(x - px, y - py), key) for key, (px, py) in layout.items()))
    distance, key = ranked[0]
    confidence = _weight(distance)
    alternatives = []
    for alt in KEY_NEIGHBORS.get(key, ()):
        if alt in KEY_TO_ZHUYIN:
            alternatives.append((alt, max(0.1, confidence - 0.2)))
    spatial = tuple((other, _weight(dist)) for dist, other in ranked[:SPATIAL_NEIGHBOR_COUNT + 1])
    return TouchHypothesis(key, confidence, tuple(alternatives), spatial)


def touch_event(session_id: str, sequence: int, timestamp_ns: int,
                surface: str, x: float, y: float) -> RawEvent:
    """Create a replayable raw event from one normalized touch point."""
    hypothesis = nearest_key(surface, x, y)
    return RawEvent(session_id, sequence, timestamp_ns, surface, "touch_down",
                    code=hypothesis.code,
                    payload={"x": x, "y": y, "confidence": hypothesis.confidence,
                             "key": hypothesis.key, "layout": LAYOUT_VERSION,
                             "neighbors": [list(pair) for pair in hypothesis.spatial]})


def touch_move(session_id: str, sequence: int, timestamp_ns: int,
               surface: str, x: float, y: float, pressure: float | None = None) -> RawEvent:
    """Record one raw contact-trajectory point. Moves carry no hypothesis;
    the normalizer skips them, so decode results are unaffected."""
    _check_surface(surface)
    _check_coordinates(x, y)
    payload: dict[str, object] = {"x": x, "y": y, "layout": LAYOUT_VERSION}
    if pressure is not None:
        payload["pressure"] = pressure
    return RawEvent(session_id, sequence, timestamp_ns, surface, "touch_move",
                    payload=payload)


def touch_up(session_id: str, sequence: int, timestamp_ns: int,
             surface: str, x: float, y: float) -> RawEvent:
    """Record a contact lift. Like moves, lifts are raw evidence only."""
    _check_surface(surface)
    _check_coordinates(x, y)
    return RawEvent(session_id, sequence, timestamp_ns, surface, "touch_up",
                    payload={"x": x, "y": y, "layout": LAYOUT_VERSION})
