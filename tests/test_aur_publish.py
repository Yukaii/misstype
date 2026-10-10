"""Replay publisher authorization without credentials, network, or a Git push."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class AURPublishAuthorizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        work = Path(self.temp.name)
        self.package = work / "package"
        self.package.mkdir()
        for name, content in {
            "PKGBUILD": "# Maintainer: Test <test@example.invalid>\n",
            ".SRCINFO": "pkgbase = fcitx5-misstype-git\n",
            "cxx20.patch": "test patch\n",
            "LICENSE": "test license\n",
        }.items():
            (self.package / name).write_text(content)
        mocks = work / "mocks.bash"
        mocks.write_text("""
git() { printf '%s\n' "$TEST_CHECKOUT_SHA"; }
gh() { printf '%s\n' "$TEST_RELEASE_PUBLISHED"; }
ssh-keyscan() { echo 'TEST: reached SSH boundary' >&2; return 73; }
""")
        self.env = dict(
            os.environ,
            BASH_ENV=str(mocks),
            AUR_SSH_PRIVATE_KEY="dummy-not-a-real-key",
            AUR_MAINTAINER="Test <test@example.invalid>",
            RUNNER_TEMP=str(work),
            GITHUB_REPOSITORY="Yukaii/misstype",
            GITHUB_REF="refs/heads/main",
            GITHUB_SHA="test-source-sha",
            TEST_CHECKOUT_SHA="test-source-sha",
            TEST_RELEASE_PUBLISHED="true",
        )

    def run_publisher(self, **changes):
        return subprocess.run(
            ["bash", str(ROOT / "script/linux/publish_aur.sh"), str(self.package)],
            env=dict(self.env, **changes), capture_output=True, text=True,
        )

    def test_unapproved_refs_and_forks_never_reach_ssh(self):
        cases = [
            {"GITHUB_REF": "refs/heads/ci/aur-publishing"},
            {"GITHUB_REF": "refs/tags/v0.3.0-rc1"},
            {"GITHUB_REF": "refs/tags/v-not-a-version"},
            {"GITHUB_REPOSITORY": "example/fork"},
        ]
        for changes in cases:
            with self.subTest(**changes):
                result = self.run_publisher(**changes)
                self.assertEqual(result.returncode, 1)
                self.assertIn("publication requires", result.stderr)
                self.assertNotIn("SSH boundary", result.stderr)

    def test_source_mismatch_never_reaches_ssh(self):
        result = self.run_publisher(TEST_CHECKOUT_SHA="different-source-sha")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Checkout does not match", result.stderr)

    def test_unpublished_or_nonstable_release_never_reaches_ssh(self):
        result = self.run_publisher(
            GITHUB_REF="refs/tags/v0.3.0", TEST_RELEASE_PUBLISHED="false",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("published stable GitHub Release", result.stderr)

    def test_main_and_published_stable_tag_reach_ssh_boundary(self):
        for ref in ("refs/heads/main", "refs/tags/v0.3.0"):
            with self.subTest(ref=ref):
                result = self.run_publisher(GITHUB_REF=ref)
                self.assertEqual(result.returncode, 73)
                self.assertIn("TEST: reached SSH boundary", result.stderr)


if __name__ == "__main__":
    unittest.main()
