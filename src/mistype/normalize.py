from collections.abc import Iterable

from .models import PhoneticToken, RawEvent


def normalize_events(events: Iterable[RawEvent]) -> list[PhoneticToken]:
    """Convert key events into stable tokens; unknown events remain observable."""
    tokens: list[PhoneticToken] = []
    span = 0
    index = 0
    for event in sorted(events, key=lambda item: item.sequence):
        if event.kind not in {"key", "gesture"} or not event.code:
            continue
        code = event.code
        if code in {"SPACE", "ENTER", "COMMIT"}:
            tokens.append(PhoneticToken(span, index, "boundary", code.lower()))
            span += 1
            index = 0
        elif code.startswith("ZH:"):
            tokens.append(PhoneticToken(span, index, "zhuyin", code[3:]))
            index += 1
        elif code.startswith("LATIN:"):
            tokens.append(PhoneticToken(span, index, "latin", code[6:]))
            index += 1
        elif len(code) == 1 and not code.isalnum():
            tokens.append(PhoneticToken(span, index, "punctuation", code))
            index += 1
        else:
            tokens.append(PhoneticToken(span, index, "latin", code))
            index += 1
    return tokens
