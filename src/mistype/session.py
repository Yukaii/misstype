from dataclasses import dataclass
from threading import RLock

from .adapters import AdapterRunner, DecoderProtocol, decode_with_fallback
from .decoder import OfflineDecoder
from .models import DecodeContext, DecodeResult, RawEvent
from .normalize import normalize_events


@dataclass
class SessionCoordinator:
    """Own input lifetime and commit policy while keeping capture model-free."""

    pause_ms: int = 700

    def __post_init__(self) -> None:
        self._events: list[RawEvent] = []
        self._revision = 0
        self._last_timestamp_ns: int | None = None
        self._decoder = OfflineDecoder()
        self._committed = ""
        self._lock = RLock()
        self._adapter_runner = AdapterRunner()

    @property
    def revision(self) -> int:
        return self._revision

    @property
    def committed_text(self) -> str:
        return self._committed

    @property
    def events(self) -> tuple[RawEvent, ...]:
        """Read-only view of the uncommitted raw trace."""
        with self._lock:
            return tuple(self._events)

    def ingest(self, event: RawEvent) -> None:
        with self._lock:
            if self._last_timestamp_ns is not None and event.timestamp_ns < self._last_timestamp_ns:
                raise ValueError("events must use monotonic timestamps")
            self._events.append(event)
            self._last_timestamp_ns = event.timestamp_ns
            self._revision += 1

    def preview(self) -> DecodeResult:
        return self._decode()

    def preview_with_adapter(self, adapter: DecoderProtocol,
                             deadline_ms: float = 200.0) -> DecodeResult:
        """Preview through a model adapter without blocking capture past the
        deadline; falls back to the offline result on timeout or staleness."""
        with self._lock:
            revision = self._revision
            events = tuple(self._events)
        context = DecodeContext(revision=revision, deadline_ms=deadline_ms)
        result = decode_with_fallback(normalize_events(events), context,
                                      adapter, self._decoder, self._adapter_runner)
        with self._lock:
            if self._revision != revision:
                return self._decode_events(tuple(self._events), self._revision)
        return result

    def maybe_commit(self, now_ns: int) -> DecodeResult | None:
        with self._lock:
            if self._last_timestamp_ns is None:
                return None
            elapsed_ms = (now_ns - self._last_timestamp_ns) / 1_000_000
            return self.commit() if elapsed_ms >= self.pause_ms else None

    def commit(self) -> DecodeResult:
        with self._lock:
            result = self._decode()
            self._committed += result.text
            self._events.clear()
            self._last_timestamp_ns = None
            self._revision += 1
            return result

    def _decode(self) -> DecodeResult:
        with self._lock:
            return self._decode_events(tuple(self._events), self._revision)

    def _decode_events(self, events: tuple[RawEvent, ...], revision: int) -> DecodeResult:
        tokens = normalize_events(events)
        return self._decoder.decode(tokens, DecodeContext(revision=revision))
