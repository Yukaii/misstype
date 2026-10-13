"""Release pinning rejects wrong assets, checksums and nonstable tags."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
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

    def asset(self, prefix="Misstype", arch="x86_64"):
        name = f"{prefix}-1.2.3-arch-{arch}.pkg.tar.zst"
        payload = b"synthetic release payload " + arch.encode()
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
                self.assertIn(f"sha256sums_x86_64=('{digest}')", text)
                self.assertNotIn("makedepends=", text)
                self.assertNotIn("build()", text)
                self.assertNotIn("SKIP", text)

    def test_aarch64_asset_is_pinned_when_published(self):
        for flavor, prefix in (("fcitx5", "Misstype"), ("ibus", "MisstypeIBus")):
            with self.subTest(flavor=flavor):
                _, x86, _ = self.asset(prefix)
                name, arm, checksum = self.asset(prefix, "aarch64")
                module.prepare(ROOT / f"linux/aur-{flavor}-bin", self.work, "v1.2.3", self.output)
                text = (self.output / "PKGBUILD").read_text()
                self.assertIn("arch=('x86_64' 'aarch64')", text)
                self.assertIn(f"sha256sums_x86_64=('{x86}')", text)
                self.assertIn(f"sha256sums_aarch64=('{arm}')", text)
                self.assertNotIn("0" * 64, text)

    def test_release_without_aarch64_asset_drops_the_architecture(self):
        self.asset()
        module.prepare(ROOT / "linux/aur-fcitx5-bin", self.work, "v1.2.3", self.output)
        text = (self.output / "PKGBUILD").read_text()
        self.assertIn("arch=('x86_64')\n", text)
        self.assertNotIn("source_aarch64", text)
        self.assertNotIn("sha256sums_aarch64", text)
        self.assertNotIn("Placeholder", text)

    def test_corrupt_aarch64_payload_fails_even_when_x86_64_is_valid(self):
        self.asset()
        name, _, checksum = self.asset(arch="aarch64")
        checksum.write_text(f"{'0' * 64}  {name}\n")
        with self.assertRaises(ValueError):
            module.prepare(ROOT / "linux/aur-fcitx5-bin", self.work, "v1.2.3", self.output)
        self.assertFalse(self.output.exists())

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

    @unittest.skipUnless(shutil.which("cmake") and shutil.which("c++"), "CMake and C++ compiler required")
    def test_conformance_harness_uses_release_driver_without_release_harness(self):
        # Older release tags have a driver but predate tests/aur-bin. Configure
        # the current harness against that tree, with stand-ins for installed
        # fcitx5 targets so this wiring check needs no Arch or fcitx5 installation.
        release = self.work / "release"
        driver = release / "linux/fcitx5/test/testmisstype.cpp"
        driver.parent.mkdir(parents=True)
        driver.write_text("int main() { return 0; }\n")
        self.assertFalse((release / "tests/aur-bin").exists())
        packages = self.work / "packages"
        packages.mkdir()
        data = self.work / "data"
        data.mkdir()
        for package, target in (("Fcitx5Core", "Core"), ("Fcitx5Utils", "Utils"),
                                ("Fcitx5ModuleTestFrontend", "Module::TestFrontend")):
            (packages / f"{package}Config.cmake").write_text(
                f"add_library(Fcitx5::{target} INTERFACE IMPORTED)\n"
                f'set(FCITX_INSTALL_PKGDATADIR "{data}")\n'
                f'set(FCITX_INSTALL_ADDONDIR "{data}")\n'
            )
        build = self.work / "conformance"
        result = subprocess.run([
            "cmake", "-S", str(ROOT / "tests/aur-bin"), "-B", str(build),
            f"-DMISSTYPE_ROOT={release}", f"-DCMAKE_PREFIX_PATH={packages}",
            "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        commands = json.loads((build / "compile_commands.json").read_text())
        self.assertEqual([entry["file"] for entry in commands], [str(driver)])


if __name__ == "__main__":
    unittest.main()
