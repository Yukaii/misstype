import time
import unittest

from mistype.adapters import (
    DecoderProtocol,
    StubModelAdapter,
    decode_with_fallback,
)
from mistype.decoder import OfflineDecoder
from mistype.models import DecodeContext, RawEvent
from mistype.normalize import normalize_events
from mistype.session import SessionCoordinator


def ni_hao_events():
    codes = ["BPMF:s", "BPMF:u", "BPMF:3", "BPMF:c", "BPMF:l", "BPMF:3"]
    return [RawEvent("test", i, i * 90_000_000, "left", "key", code)
            for i, code in enumerate(codes)]


class AdapterTests(unittest.TestCase):
    def test_both_decoders_satisfy_the_protocol(self):
        self.assertIsInstance(OfflineDecoder(), DecoderProtocol)
        self.assertIsInstance(StubModelAdapter(), DecoderProtocol)

    def test_context_revision_flows_to_the_result(self):
        tokens = normalize_events(ni_hao_events())
        result = OfflineDecoder().decode(tokens, DecodeContext(revision=7))
        self.assertEqual((result.revision, result.text), (7, "你好"))

    def test_fast_adapter_result_is_accepted(self):
        tokens = normalize_events(ni_hao_events())
        result = decode_with_fallback(tokens, DecodeContext(revision=2),
                                      StubModelAdapter())
        self.assertEqual(result.decoder_id, "stub-model")
        self.assertEqual((result.text, result.revision), ("你好", 2))

    def test_slow_adapter_never_blocks_capture(self):
        tokens = normalize_events(ni_hao_events())
        started = time.perf_counter()
        result = decode_with_fallback(tokens, DecodeContext(revision=0, deadline_ms=10),
                                      StubModelAdapter(latency_ms=5000))
        elapsed_ms = (time.perf_counter() - started) * 1000
        self.assertEqual(result.decoder_id, "offline-fixture")
        self.assertEqual(result.text, "你好")
        self.assertLess(elapsed_ms, 1000)

    def test_failing_adapter_falls_back_offline(self):
        tokens = normalize_events(ni_hao_events())
        result = decode_with_fallback(tokens, DecodeContext(revision=0),
                                      StubModelAdapter(fail=True))
        self.assertEqual((result.decoder_id, result.text),
                         ("offline-fixture", "你好"))

    def test_stale_adapter_result_is_rejected(self):
        tokens = normalize_events(ni_hao_events())
        result = decode_with_fallback(tokens, DecodeContext(revision=4),
                                      StubModelAdapter(wrong_revision=True))
        self.assertEqual(result.decoder_id, "offline-fixture")
        self.assertEqual(result.revision, 4)

    def test_coordinator_preview_with_slow_adapter_stays_offline(self):
        session = SessionCoordinator()
        for event in ni_hao_events():
            session.ingest(event)
        result = session.preview_with_adapter(StubModelAdapter(latency_ms=5000),
                                              deadline_ms=10)
        self.assertEqual(result.decoder_id, "offline-fixture")
        self.assertEqual(result.text, "你好")
        committed = session.commit()
        self.assertEqual(session.committed_text, committed.text)


if __name__ == "__main__":
    unittest.main()
