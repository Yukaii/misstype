import time
import unittest
from threading import Event, Thread

from misstype.adapters import (
    DecoderProtocol,
    StubModelAdapter,
    AdapterRunner,
    decode_with_fallback,
)
from misstype.decoder import OfflineDecoder
from misstype.models import DecodeContext, RawEvent
from misstype.normalize import normalize_events
from misstype.session import SessionCoordinator


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

    def test_runner_cancels_timeout_and_refuses_overlapping_work(self):
        runner = AdapterRunner()
        context = DecodeContext(revision=0, deadline_ms=1)
        result = decode_with_fallback([], context, StubModelAdapter(latency_ms=500),
                                      runner=runner)
        self.assertEqual(result.decoder_id, "offline-fixture")
        self.assertTrue(context.cancel_event.is_set())
        # The cancelled worker may still be unwinding; no second worker is
        # admitted until that slot is free.
        second = decode_with_fallback([], DecodeContext(deadline_ms=1),
                                      StubModelAdapter(latency_ms=500), runner=runner)
        self.assertEqual(second.decoder_id, "offline-fixture")

    def test_coordinator_rejects_model_result_after_new_input(self):
        started, release = Event(), Event()

        class Controlled:
            decoder_id = "controlled"
            decoder_version = "1"

            def decode(self, tokens, context=None):
                started.set()
                release.wait(1)
                return StubModelAdapter().decode(tokens, context)

        session = SessionCoordinator()
        for event in ni_hao_events():
            session.ingest(event)
        result_box = []
        thread = Thread(target=lambda: result_box.append(
            session.preview_with_adapter(Controlled(), deadline_ms=1000)))
        thread.start()
        self.assertTrue(started.wait(1))
        session.ingest(RawEvent("test", 6, 600_000_000, "left", "key", "LATIN:AI"))
        release.set()
        thread.join(1)
        self.assertEqual(result_box[0].text, "你好AI")
        self.assertEqual(result_box[0].revision, session.revision)


if __name__ == "__main__":
    unittest.main()
