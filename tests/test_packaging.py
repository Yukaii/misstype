import pathlib
import plistlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class PackagingMetadataTests(unittest.TestCase):
    def test_input_source_has_localized_name_and_icon_metadata(self):
        with (ROOT / "Resources" / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)

        self.assertEqual(info["CFBundleDisplayName"], "Mistype")
        self.assertEqual(info["tsInputMethodIconFileKey"], "MistypeMenuIcon.tiff")
        self.assertTrue(info["LSHasLocalizedDisplayName"])

        mode = info["ComponentInputModeDict"]["tsInputModeListKey"][
            "org.mistype.inputmethod.Mistype.Zhuyin"
        ]
        self.assertEqual(mode["tsInputModeMenuIconFileKey"], "MistypeMenuIcon.tiff")
        self.assertEqual(mode["tsInputModePaletteIconFileKey"], "MistypeMenuIcon.tiff")

        icon = ROOT / "Resources" / "MistypeIcon.png"
        self.assertTrue(icon.is_file())
        self.assertGreater(icon.stat().st_size, 0)
        svg = ROOT / "Resources" / "MistypeIcon.svg"
        self.assertTrue(svg.is_file())
        svg_text = svg.read_text()
        self.assertIn("viewBox=\"0 0 16 16\"", svg_text)
        self.assertEqual(svg_text.count("<path "), 3)
        menu_svg = ROOT / "Resources" / "MistypeMenuIcon.svg"
        self.assertTrue(menu_svg.is_file())
        menu_svg_text = menu_svg.read_text()
        self.assertIn("viewBox=\"0 0 22 16\"", menu_svg_text)
        self.assertIn('shape-rendering="crispEdges"', menu_svg_text)
        menu_icon = ROOT / "Resources" / "MistypeMenuIcon.tiff"
        self.assertTrue(menu_icon.is_file())
        self.assertGreater(menu_icon.stat().st_size, 0)
        try:
            dimensions = subprocess.check_output(
                ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(menu_icon)],
                text=True,
            )
        except FileNotFoundError:
            self.skipTest("sips is only available on macOS")
        self.assertIn("pixelWidth: 22", dimensions)
        self.assertIn("pixelHeight: 16", dimensions)

        for locale, expected in {
            "en.lproj": "Mistype Bopomofo",
            "zh-Hant.lproj": "Mistype 注音",
        }.items():
            strings = (ROOT / "Resources" / locale / "InfoPlist.strings").read_text()
            self.assertIn(
                f'"org.mistype.inputmethod.Mistype.Zhuyin" = "{expected}";',
                strings,
            )


if __name__ == "__main__":
    unittest.main()
