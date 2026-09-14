"""Model-backed decoders behind one contract (M4 seam, no weights shipped).

The offline decoder is always available. Adapters run behind a strict
deadline: a slow, failed, or stale result never blocks capture and never
overwrites the offline result. StubModelAdapter locks that timeout and
staleness behavior with a configurable stand-in until a real local model
is chosen.
"""

import time
from collections.abc import Sequence
from concurrent import futures
from dataclasses import replace
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
            time.sleep(self._latency_ms / 1000)
        revision = context.revision if context is not None else 0
        if self._wrong_revision:
            revision += 1
        base = OfflineDecoder().decode(tokens, DecodeContext(revision=revision))
        return replace(base, decoder_id=self.decoder_id,
                       decoder_version=self.decoder_version)


def decode_with_fallback(tokens: Sequence[PhoneticToken], context: DecodeContext,
                         adapter: DecoderProtocol,
                         offline: OfflineDecoder | None = None) -> DecodeResult:
    """Decode offline immediately; accept the adapter result only when it is
    on time, healthy, and stamped for the current revision."""
    offline = offline or OfflineDecoder()
    fallback = offline.decode(tokens, context)
    executor = futures.ThreadPoolExecutor(max_workers=1)
    future = executor.submit(adapter.decode, list(tokens), context)
    try:
        candidate = future.result(timeout=max(0.0, context.deadline_ms) / 1000)
    except Exception:
        # Timeout, adapter crash, cancellation: keep the offline result and
        # let the stray worker finish in the background, off the capture path.
        return fallback
    finally:
        executor.shutdown(wait=False)
    if candidate.revision != context.revision:
        return fallback
    return candidate
