import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "plex_release", Path(__file__).parents[1] / "scripts" / "plex-release.py"
)
plex_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plex_release)


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.release = {
            "version": "1.43.4.10903-e5521bd8c",
            "items_added": "(GPU) Added support for HEVC",
            "items_fixed": "(Database) Fixed search index corruption",
        }

    def test_only_matching_public_release_is_described(self):
        notes = plex_release.release_changelog(
            self.release, "1.43.4.10903-e5521bd8c", "1.43.4.10903"
        )
        self.assertIn("Plex Media Server 1.43.4.10903-e5521bd8c", notes)
        self.assertIn("## Added", notes)
        self.assertIn("## Fixed", notes)

    def test_fourth_component_and_hash_must_match(self):
        for tag, numeric in (
            ("1.43.4.10904-e5521bd8c", "1.43.4.10904"),
            ("1.43.4.10903-aaaaaaaaa", "1.43.4.10903"),
            ("1.43.4.10903-e5521bd8c", "1.43.4"),
            ("1.43.4.10903-e5521bd8c-arm64", "1.43.4.10903"),
            ("latest", "1.43.4.10903"),
        ):
            with self.subTest(tag=tag, numeric=numeric), self.assertRaises(ValueError):
                plex_release.release_changelog(self.release, tag, numeric)

    def test_missing_notes_are_not_invented(self):
        self.release["items_added"] = ""
        self.release["items_fixed"] = ""
        with self.assertRaises(ValueError):
            plex_release.release_changelog(
                self.release, "1.43.4.10903-e5521bd8c", "1.43.4.10903"
            )


if __name__ == "__main__":
    unittest.main()
