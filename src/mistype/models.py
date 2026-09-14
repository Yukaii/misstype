from dataclasses import dataclass, field
from typing import Any, Literal


@dataclass(frozen=True)
class RawEvent:
    session_id: str
    sequence: int
    timestamp_ns: int
    surface: Literal["left", "right"]
    kind: str
    code: str | None = None
    payload: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "RawEvent":
        return cls(
            session_id=value["session_id"], sequence=int(value["sequence"]),
            timestamp_ns=int(value["timestamp_ns"]), surface=value["surface"],
            kind=value["kind"], code=value.get("code"), payload=value.get("payload", {}),
        )


@dataclass(frozen=True)
class PhoneticToken:
    span_id: int
    index: int
    kind: Literal["zhuyin", "latin", "punctuation", "boundary"]
    value: str
    tone: str | None = None
    confidence: float = 1.0
    alternatives: tuple[tuple[str, float], ...] = ()


@dataclass(frozen=True)
class DecodeContext:
    """Per-request decode budget. Adapters must respect the deadline and
    stamp the revision so stale results can be rejected downstream."""

    revision: int = 0
    deadline_ms: float = 200.0


@dataclass(frozen=True)
class DecodeResult:
    revision: int
    text: str
    confidence: float
    decoder_id: str
    decoder_version: str
    latency_ms: float
    alignment: tuple[tuple[str, str], ...] = ()

