"""Release pinning rejects wrong assets, checksums and nonstable tags."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prepare_aur_bin", ROOT / "script/linux/prepare_aur_bin.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BinaryRecipeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.output = self.work / "output"

    def asset(self, prefix="Misstype"):
        name = f"{prefix}-1.2.3-arch-x86_64.pkg.tar.zst"
        payload = b"synthetic release payload"
        (self.work / name).write_bytes(payload)
        digest = hashlib.sha256(payload).hexdigest()
        checksum = self.work / (name + ".sha256")
        checksum.write_text(f"{digest}  {name}\n")
        return name, digest, checksum

    def test_both_frontends_pin_exact_release_without_build_dependencies(self):
        for flavor, prefix in (("fcitx5", "Misstype"), ("ibus", "MisstypeIBus")):
            with self.subTest(flavor=flavor):
                _, digest, _ = self.asset(prefix)
                module.prepare(ROOT / f"linux/aur-{flavor}-bin", self.work, "v1.2.3", self.output)
                text = (self.output / "PKGBUILD").read_text()
                self.assertIn("pkgver=1.2.3\npkgrel=1", text)
                self.assertIn(f"sha256sums=('{digest}')", text)
                self.assertNotIn("makedepends=", text)
                self.assertNotIn("build()", text)
                self.assertNotIn("SKIP", text)

    def test_corrupt_payload_wrong_filename_and_malformed_checksum_fail(self):
        name, digest, checksum = self.asset()
        for contents in (f"{'0' * 64}  {name}\n", f"{digest}  other.pkg.tar.zst\n", "SKIP\n"):
            with self.subTest(contents=contents):
                checksum.write_text(contents)
                with self.assertRaises(ValueError):
                    module.prepare(ROOT / "linux/aur-fcitx5-bin", self.work, "v1.2.3", self.output)
                self.assertFalse(self.output.exists())

    def test_prerelease_branch_and_injection_are_rejected(self):
        for tag in ("main", "v1.2.3-rc1", "v1.2.3;command", "1.2.3"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                module.prepare(ROOT / "linux/aur-fcitx5-bin", self.work, tag, self.output)


if __name__ == "__main__":
    unittest.main()
