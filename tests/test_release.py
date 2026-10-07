import importlib.util
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "next_release_tag", Path(__file__).resolve().parents[1] / "script/next_release_tag.py")
next_release_tag = importlib.util.module_from_spec(spec)
spec.loader.exec_module(next_release_tag)


class ReleaseVersionTests(unittest.TestCase):
    def test_all_bumps_reset_lower_components(self):
        for bump, expected in [("major", "v2.0.0"), ("minor", "v1.3.0"), ("patch", "v1.2.4")]:
            with self.subTest(bump=bump):
                self.assertEqual(next_release_tag.next_tag(["v1.2.3"], bump), expected)

    def test_versions_are_sorted_numerically(self):
        self.assertEqual(next_release_tag.next_tag(
            ["v0.9.9", "v0.10.0", "v0.2.0"], "minor"), "v0.11.0")

    def test_prereleases_and_unrelated_tags_do_not_set_the_baseline(self):
        self.assertEqual(next_release_tag.next_tag(
            ["v0.2.0", "v9.0.0-rc1", "experiment", "v01.0.0", "1.0.0", "v3.0.0+build"],
            "patch"), "v0.2.1")

    def test_first_release_starts_from_zero(self):
        for bump, expected in [("major", "v1.0.0"), ("minor", "v0.1.0"), ("patch", "v0.0.1")]:
            with self.subTest(bump=bump):
                self.assertEqual(next_release_tag.next_tag([], bump), expected)

    def test_invalid_bump_fails(self):
        with self.assertRaises(ValueError):
            next_release_tag.next_tag(["v0.2.0"], "invalid")
