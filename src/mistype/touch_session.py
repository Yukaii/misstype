from .models import DecodeResult
from .session import SessionCoordinator
from .touch import touch_event


class TouchSession:
    """Convenience facade for a split-surface simulator or platform adapter."""

    def __init__(self, session_id: str = "touch", pause_ms: int = 700) -> None:
        self._coordinator = SessionCoordinator(pause_ms=pause_ms)
        self._session_id = session_id
        self._sequence = 0

    def touch(self, surface: str, x: float, y: float, timestamp_ns: int) -> None:
        event = touch_event(self._session_id, self._sequence, timestamp_ns, surface, x, y)
        self._coordinator.ingest(event)
        self._sequence += 1

    def preview(self) -> DecodeResult:
        return self._coordinator.preview()

    def commit(self) -> DecodeResult:
        return self._coordinator.commit()

    @property
    def committed_text(self) -> str:
        return self._coordinator.committed_text
