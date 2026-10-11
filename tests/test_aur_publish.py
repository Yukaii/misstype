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
            ".SRCINFO": "pkgbase = fcitx5-misstype-git\npkgname = fcitx5-misstype-git\n",
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

    def run_publisher(self, name="fcitx5-misstype-git", **changes):
        return subprocess.run(
            ["bash", str(ROOT / "script/linux/publish_aur.sh"), str(self.package), name],
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

    def test_ibus_does_not_require_fcitx5_patch(self):
        (self.package / "cxx20.patch").unlink()
        (self.package / ".SRCINFO").write_text(
            "pkgbase = ibus-misstype-git\npkgname = ibus-misstype-git\n"
        )
        result = self.run_publisher(name="ibus-misstype-git")
        self.assertEqual(result.returncode, 73)
        self.assertIn("TEST: reached SSH boundary", result.stderr)

    def test_binary_packages_require_matching_published_release_tag(self):
        for name in ("fcitx5-misstype-bin", "ibus-misstype-bin"):
            (self.package / ".SRCINFO").write_text(
                f"pkgbase = {name}\n\tpkgver = 0.4.2\npkgname = {name}\n"
            )
            for ref, published, expected in (
                ("refs/heads/main", "true", 1),
                ("refs/tags/v0.4.1", "true", 1),
                ("refs/tags/v0.4.2", "false", 1),
                ("refs/tags/v0.4.2", "true", 73),
            ):
                with self.subTest(name=name, ref=ref, published=published):
                    result = self.run_publisher(name=name, GITHUB_REF=ref, TEST_RELEASE_PUBLISHED=published)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual("SSH boundary" in result.stderr, expected == 73)

    def test_unsupported_name_and_mismatched_metadata_never_reach_ssh(self):
        for name in ("../other", "unknown-package", "ibus-misstype-git"):
            with self.subTest(name=name):
                result = self.run_publisher(name=name)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("SSH boundary", result.stderr)

    def test_multiple_package_names_never_reach_ssh(self):
        with (self.package / ".SRCINFO").open("a") as info:
            info.write("pkgname = other-package\n")
        result = self.run_publisher()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("SSH boundary", result.stderr)

    def test_publish_destination_file_list_and_unchanged_noop(self):
        mocks = Path(self.env["BASH_ENV"])
        mocks.write_text("""
git() {
    printf '%s\\n' "$*" >> "$TEST_GIT_LOG"
    if [[ $1 == rev-parse ]]; then printf '%s\\n' "$TEST_CHECKOUT_SHA";
    elif [[ $1 == clone ]]; then
        mkdir -p "$3"
        if [[ -n ${TEST_REMOTE_VERSION:-} ]]; then
            printf '\tpkgver = %s\n\tpkgrel = %s\n' "$TEST_REMOTE_VERSION" "$TEST_REMOTE_PKGREL" > "$3/.SRCINFO"
        fi
    elif [[ $3 == diff && $4 == --cached && $5 == --quiet ]]; then
        return "$TEST_DIFF_STATUS"
    fi
}
gh() { printf '%s\\n' "$TEST_RELEASE_PUBLISHED"; }
ssh-keyscan() { echo 'test host key'; }
ssh-keygen() { echo '256 SHA256:RFzBCUItH9LZS0cKB5UE6ceAYhBD5C8GeOBip8Z11+4 test'; }
""")
        work = Path(self.temp.name)
        for name, files in (
            ("fcitx5-misstype-git", "PKGBUILD .SRCINFO LICENSE cxx20.patch"),
            ("ibus-misstype-git", "PKGBUILD .SRCINFO LICENSE"),
            ("fcitx5-misstype-bin", "PKGBUILD .SRCINFO LICENSE"),
            ("ibus-misstype-bin", "PKGBUILD .SRCINFO LICENSE"),
        ):
            (self.package / ".SRCINFO").write_text(f"pkgbase = {name}\n\tpkgver = 0.4.2\n\tpkgrel = 1\npkgname = {name}\n")
            for changed in (False, True):
                with self.subTest(name=name, changed=changed):
                    log = work / f"{name}-{changed}.log"
                    summary = work / "summary"
                    result = self.run_publisher(
                        name=name, TEST_GIT_LOG=str(log),
                        TEST_DIFF_STATUS=str(int(changed)),
                        GITHUB_STEP_SUMMARY=str(summary),
                        GITHUB_REF="refs/tags/v0.4.2" if name.endswith("-bin") else "refs/heads/main",
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    commands = log.read_text()
                    self.assertIn(f"clone ssh://aur@aur.archlinux.org/{name}.git", commands)
                    self.assertIn(f"add -- {files}", commands)
                    self.assertEqual("push origin HEAD:master" in commands, changed)
                    self.assertNotIn("--force", commands)
                    if changed:
                        self.assertIn(f"https://aur.archlinux.org/packages/{name}", summary.read_text())
            if name.endswith("-bin"):
                for version, pkgrel in (("0.4.3", "1"), ("0.4.2", "2")):
                    with self.subTest(name=name, remote_version=version, pkgrel=pkgrel):
                        log = work / "downgrade.log"
                        if log.exists():
                            log.unlink()
                        result = self.run_publisher(
                            name=name, GITHUB_REF="refs/tags/v0.4.2",
                            TEST_GIT_LOG=str(log), TEST_DIFF_STATUS="1",
                            TEST_REMOTE_VERSION=version, TEST_REMOTE_PKGREL=pkgrel,
                            GITHUB_STEP_SUMMARY=str(work / "summary"),
                        )
                        self.assertEqual(result.returncode, 1)
                        self.assertIn("Refusing to downgrade", result.stderr)
                        self.assertNotIn("push origin", log.read_text())

    def test_missing_or_symlinked_payload_never_reaches_ssh(self):
        license = self.package / "LICENSE"
        license.unlink()
        result = self.run_publisher()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("SSH boundary", result.stderr)
        license.symlink_to(self.package / "PKGBUILD")
        result = self.run_publisher()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("SSH boundary", result.stderr)


if __name__ == "__main__":
    unittest.main()
