from .phonetic import KEY_TO_ZHUYIN

# Physical-key neighborhoods. The order is from closest to farther fallback.
KEY_NEIGHBORS = {
    "q": ("1", "w"), "w": ("q", "e", "2"), "e": ("w", "r", "3"),
    "r": ("e", "t", "4"), "t": ("r", "y", "5"), "y": ("t", "u", "6"),
    "u": ("y", "i", "7"), "i": ("u", "o", "8"), "o": ("i", "p", "9"),
    "p": ("o", "0", "["), "a": ("q", "s", "z"), "s": ("a", "d", "x"),
    "d": ("s", "f", "e"), "f": ("d", "g", "r"), "g": ("f", "h", "t"),
    "h": ("g", "j", "y"), "j": ("h", "k", "u"), "k": ("j", "l", "i"),
    "l": ("k", ";", "o"), "z": ("a", "x"), "x": ("z", "c", "s"),
    "c": ("x", "v", "d"), "v": ("c", "b", "f"), "b": ("v", "n", "g"),
    "n": ("b", "m", "h"), "m": ("n", ",", "j"),
}


def fuzzy_candidates(key: str) -> tuple[tuple[str, float], ...]:
    """Return Zhuyin alternatives for a physical key, highest confidence first."""
    if key not in KEY_TO_ZHUYIN:
        return ()
    result = [(KEY_TO_ZHUYIN[key], 1.0)]
    for distance, neighbor in enumerate(KEY_NEIGHBORS.get(key, ()), start=1):
        if neighbor in KEY_TO_ZHUYIN:
            result.append((KEY_TO_ZHUYIN[neighbor], max(0.35, 0.85 - distance * 0.15)))
    return tuple(result)
