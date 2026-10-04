import json
import unittest

from misstype.models import RawEvent
from misstype.phonetic import KEY_TO_ZHUYIN
from misstype.normalize import normalize_events
from misstype.touch import (
    LAYOUT_VERSION,
    SPATIAL_NEIGHBOR_COUNT,
    key_position,
    layout_keys,
    nearest_key,
    payload_candidates,
    touch_event,
    touch_move,
    touch_up,
)
from misstype.touch_session import TouchSession


class TouchLayoutTests(unittest.TestCase):
    def test_every_zhuyin_key_is_reachable_on_exactly_one_surface(self):
        left = layout_keys("left")
        right = layout_keys("right")
        for key in KEY_TO_ZHUYIN:
            surfaces = [name for name, layout in (("left", left), ("right", right))
                        if key in layout]
            self.assertEqual(surfaces, [key_position(key)[0]],
                             f"key {key!r} must live on exactly one surface")

    def test_tapping_a_key_center_returns_that_key(self):
        for surface in ("left", "right"):
            for key, (x, y) in layout_keys(surface).items():
                with self.subTest(surface=surface, key=key):
                    hypothesis = nearest_key(surface, x, y)
                    self.assertEqual(hypothesis.key, key)
                    self.assertEqual(hypothesis.confidence, 1.0)

    def test_every_tone_key_has_a_touch_target(self):
        # SPACE is a boundary gesture, not a touch target: neutral tone (˙)
        # via touch is a known gap, tracked in docs/architecture.md.
        for key in ("3", "4", "6", "7"):
            surface, (x, y) = key_position(key)
            hypothesis = nearest_key(surface, x, y)
            self.assertEqual(hypothesis.key, key)
            # Tone keys have no fuzzy Zhuyin neighbors; they must be exact so
            # the normalizer can attach the tone to the preceding symbol.
            self.assertEqual(hypothesis.code, f"BPMF:{key}")

    def test_legacy_compact_point_still_maps_to_a(self):
        self.assertEqual(nearest_key("left", 0.30, 0.50).key, "a")

    def test_layout_helpers_reject_bad_input(self):
        with self.assertRaises(ValueError):
            layout_keys("middle")
        with self.assertRaises(KeyError):
            key_position("?")
        with self.assertRaises(ValueError):
            nearest_key("left", 1.1, 0.5)

    def test_touch_event_preserves_raw_trace_evidence(self):
        surface, (x, y) = key_position("s")
        event = touch_event("trace", 0, 0, surface, x, y)
        self.assertEqual(event.code, "BPMF_FUZZY:s")
        self.assertEqual(event.payload["x"], x)
        self.assertEqual(event.payload["y"], y)
        self.assertEqual(event.payload["key"], "s")
        self.assertEqual(event.payload["layout"], LAYOUT_VERSION)

    def test_touch_session_spells_ni_hao_from_layout_taps(self):
        session = TouchSession()
        timestamp = 0
        for key in ("s", "u", "3", "c", "l", "3"):
            surface, (x, y) = key_position(key)
            session.touch(surface, x, y, timestamp)
            timestamp += 90_000_000
        self.assertEqual(session.preview().text, "你好")
        self.assertEqual(session.commit().text, "你好")

    def test_trajectory_points_are_kept_raw_without_changing_decode(self):
        session = TouchSession()
        surface, (x, y) = key_position("s")
        session.touch(surface, x, y, 0)
        session.move(surface, x + 0.02, y + 0.01, 10_000_000, pressure=0.5)
        session.move(surface, x + 0.04, y + 0.02, 20_000_000)
        session.release(surface, x + 0.04, y + 0.02, 30_000_000)
        kinds = [event.kind for event in session.events]
        self.assertEqual(kinds, ["touch_down", "touch_move", "touch_move", "touch_up"])
        move = session.events[1]
        self.assertEqual(move.payload["x"], x + 0.02)
        self.assertEqual(move.payload["pressure"], 0.5)
        # Trajectory points carry no hypothesis and are skipped downstream.
        self.assertIsNone(move.code)
        self.assertEqual(normalize_events(session.events)[0].value, "ㄋ")

    def test_trajectory_helpers_validate_surface_and_coordinates(self):
        with self.assertRaises(ValueError):
            nearest_key("middle", 0.5, 0.5)
        with self.assertRaises(ValueError):
            touch_move("trace", 0, 0, "left", 1.5, 0.5)
        with self.assertRaises(ValueError):
            touch_up("trace", 0, 0, "right", 0.5, -0.1)

    def test_spatial_neighbors_rank_by_distance(self):
        hypothesis = nearest_key("left", 0.55, 0.755)
        self.assertEqual(hypothesis.key, "s")
        self.assertEqual(len(hypothesis.spatial), SPATIAL_NEIGHBOR_COUNT + 1)
        self.assertEqual(hypothesis.spatial[0][0], "s")
        keys = [key for key, _ in hypothesis.spatial]
        self.assertEqual(len(set(keys)), len(keys))
        weights = [weight for _, weight in hypothesis.spatial]
        self.assertTrue(all(0.1 <= weight <= 1.0 for weight in weights))
        self.assertEqual(weights, sorted(weights, reverse=True))
        self.assertIn("x", keys)  # spatially adjacent to the tap

    def test_touch_event_embeds_json_serializable_spatial_payload(self):
        surface, (x, y) = key_position("s")
        event = touch_event("trace", 0, 0, surface, x, y)
        neighbors = event.payload["neighbors"]
        self.assertEqual(neighbors[0], ["s", event.payload["confidence"]])
        json.dumps(event.payload)  # must survive a JSONL round-trip

    def test_normalizer_prefers_spatial_payload_over_keyboard_neighbors(self):
        event = RawEvent("test", 0, 0, "left", "touch_down", "BPMF_FUZZY:s",
                         {"neighbors": [["d", 0.9], ["s", 0.4]]})
        tokens = normalize_events([event])
        self.assertEqual(tokens[0].value, "ㄎ")
        self.assertEqual(tokens[0].alternatives, (("ㄋ", 0.4),))

    def test_malformed_spatial_payload_falls_back_to_keyboard_neighbors(self):
        for payload in ({"neighbors": "junk"}, {"neighbors": [["?", 0.9]]}, {}):
            event = RawEvent("test", 0, 0, "left", "touch_down", "BPMF_FUZZY:s", payload)
            tokens = normalize_events([event])
            self.assertEqual(tokens[0].value, "ㄋ")

    def test_payload_candidates_clamps_weights(self):
        candidates = payload_candidates({"neighbors": [["s", 9.0], ["d", -2.0]]})
        self.assertEqual(candidates, (("ㄋ", 1.0), ("ㄎ", 0.1)))
        self.assertEqual(payload_candidates(None), ())
        self.assertEqual(payload_candidates({"neighbors": []}), ())


if __name__ == "__main__":
    unittest.main()
