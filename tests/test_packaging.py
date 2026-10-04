import pathlib
import plistlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class PackagingMetadataTests(unittest.TestCase):
    def test_input_source_has_localized_name_and_icon_metadata(self):
        with (ROOT / "Resources" / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)

        self.assertEqual(info["CFBundleDisplayName"], "Misstype")
        self.assertEqual(info["tsInputMethodIconFileKey"], "MisstypeMenuIcon.tiff")
        self.assertTrue(info["LSHasLocalizedDisplayName"])

        mode = info["ComponentInputModeDict"]["tsInputModeListKey"][
            "org.misstype.inputmethod.Misstype.Zhuyin"
        ]
        self.assertEqual(mode["tsInputModeMenuIconFileKey"], "MisstypeMenuIcon.tiff")
        self.assertEqual(mode["tsInputModePaletteIconFileKey"], "MisstypeMenuIcon.tiff")

        icon = ROOT / "Resources" / "MisstypeIcon.png"
        self.assertTrue(icon.is_file())
        self.assertGreater(icon.stat().st_size, 0)
        svg = ROOT / "Resources" / "MisstypeIcon.svg"
        self.assertTrue(svg.is_file())
        svg_text = svg.read_text()
        self.assertIn('viewBox="0 0 16 16"', svg_text)
        self.assertIn('#262C34', svg_text)
        menu_svg = ROOT / "Resources" / "MisstypeMenuIcon.svg"
        self.assertTrue(menu_svg.is_file())
        menu_svg_text = menu_svg.read_text()
        self.assertIn('viewBox="0 0 22 16"', menu_svg_text)
        self.assertIn('shape-rendering="crispEdges"', menu_svg_text)
        menu_icon = ROOT / "Resources" / "MisstypeMenuIcon.tiff"
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
            "en.lproj": "Misstype Bopomofo",
            "zh-Hant.lproj": "隨打注音",
            "zh-Hans.lproj": "随打注音",
            "ja.lproj": "随打注音",
        }.items():
            strings = (ROOT / "Resources" / locale / "InfoPlist.strings").read_text()
            self.assertIn(
                f'"org.misstype.inputmethod.Misstype.Zhuyin" = "{expected}";',
                strings,
            )


if __name__ == "__main__":
    unittest.main()
