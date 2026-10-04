"""Model-backed decoders behind one contract (M4 seam, no weights shipped).

The offline decoder is always available. Adapters run behind a strict
deadline: a slow, failed, or stale result never blocks capture and never
overwrites the offline result. StubModelAdapter locks that timeout and
staleness behavior with a configurable stand-in until a real local model
is chosen.
"""

import time
from collections.abc import Sequence
from concurrent.futures import Future
from dataclasses import replace
from threading import Lock, Thread
from typing import Protocol, runtime_checkable

from .decoder import OfflineDecoder
from .models import DecodeContext, DecodeResult, PhoneticToken


@runtime_checkable
class DecoderProtocol(Protocol):
    """Every decoder accepts tokens plus a budget and stamps the revision."""

    decoder_id: str
    decoder_version: str

    def decode(self, tokens: Sequence[PhoneticToken],
               context: DecodeContext | None = None) -> DecodeResult: ...


class StubModelAdapter:
    """Configurable stand-in for a future local model."""

    decoder_id = "stub-model"
    decoder_version = "0.0"

    def __init__(self, latency_ms: float = 0.0, fail: bool = False,
                 wrong_revision: bool = False) -> None:
        self._latency_ms = latency_ms
        self._fail = fail
        self._wrong_revision = wrong_revision

    def decode(self, tokens: Sequence[PhoneticToken],
               context: DecodeContext | None = None) -> DecodeResult:
        if self._fail:
            raise RuntimeError("stub model failure")
        if self._latency_ms > 0:
            if context is not None and context.cancel_event.wait(self._latency_ms / 1000):
                raise TimeoutError("model request cancelled")
            time.sleep(0)
        revision = context.revision if context is not None else 0
        if self._wrong_revision:
            revision += 1
        base = OfflineDecoder().decode(tokens, DecodeContext(revision=revision))
        return replace(base, decoder_id=self.decoder_id,
                       decoder_version=self.decoder_version)


class AdapterRunner:
    """One cancellable, daemon-backed adapter slot.

    Python cannot safely kill an arbitrary model thread. The runner therefore
    admits at most one request, signals cancellation on timeout, and refuses
    new work while an uncooperative adapter is still finishing.
    """

    def __init__(self) -> None:
        self._lock = Lock()
        self._busy = False
        self._cancel: object | None = None

    def run(self, adapter: DecoderProtocol, tokens: Sequence[PhoneticToken],
            context: DecodeContext, timeout_s: float) -> DecodeResult | None:
        with self._lock:
            if self._busy:
                return None
            self._busy = True
            self._cancel = context.cancel_event
        future: Future[DecodeResult] = Future()

        def work() -> None:
            try:
                future.set_result(adapter.decode(list(tokens), context))
            except BaseException as error:
                future.set_exception(error)
            finally:
                with self._lock:
                    self._busy = False
                    self._cancel = None

        Thread(target=work, daemon=True, name="misstype-adapter").start()
        try:
            return future.result(timeout=timeout_s)
        except Exception:
            context.cancel_event.set()
            return None


_DEFAULT_RUNNER = AdapterRunner()


def decode_with_fallback(tokens: Sequence[PhoneticToken], context: DecodeContext,
                         adapter: DecoderProtocol,
                         offline: OfflineDecoder | None = None,
                         runner: AdapterRunner | None = None) -> DecodeResult:
    """Decode offline immediately; accept the adapter result only when it is
    on time, healthy, and stamped for the current revision."""
    offline = offline or OfflineDecoder()
    fallback = offline.decode(tokens, context)
    candidate = (runner or _DEFAULT_RUNNER).run(
        adapter, tokens, context, max(0.0, context.deadline_ms) / 1000)
    if candidate is None:
        return fallback
    if candidate.revision != context.revision:
        return fallback
    return candidate
