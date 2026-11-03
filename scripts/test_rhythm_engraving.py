"""Validate frozen MuseScore rhythm vectors without installing the renderer."""
import hashlib
import json
import math
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "frontend/IPadApp/IPadApp/Resources"


class RhythmEngravingTests(unittest.TestCase):
    def test_all_pieces_have_compact_musescore_outlines_and_exact_notehead_anchors(self):
        self.check_version("v2")

    def test_classical_and_legacy_pieces_share_a_complete_current_engraving(self):
        self.check_version("v3")

    def check_version(self, version):
        raw = (RESOURCES / ("rhythm-puzzle-" + version + ".json")).read_bytes()
        catalog = json.loads(raw)
        ink = json.loads((RESOURCES / ("rhythm-engraving-" + version + ".json")).read_bytes())
        self.assertEqual(ink["renderer"], "MuseScore Studio 4.6.3 / Leland")
        self.assertEqual(ink["catalog_sha256"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(set(ink["tiles"]), {t["id"] for t in catalog["tiles"]})
        for tile in catalog["tiles"]:
            with self.subTest(piece=tile["id"]):
                drawing = ink["tiles"][tile["id"]]
                self.assertGreater(drawing["width"], 20)
                self.assertLess(drawing["width"], 180)
                self.assertEqual(drawing["baseline"], 58)
                self.assertEqual(len(drawing["symbol_xs"]), len(tile["symbols"]))
                self.assertEqual(drawing["symbol_xs"], sorted(drawing["symbol_xs"]))
                self.assertTrue(all(0 < x < drawing["width"] for x in drawing["symbol_xs"]))
                self.assertTrue(drawing["paths"])
                for path in drawing["paths"]:
                    self.assertIsInstance(path["fill"], bool)
                    for command in path["commands"]:
                        self.assertEqual(len(command["values"]), {"M":2,"L":2,"C":6,"Q":4,"Z":0}[command["op"]])
                        self.assertTrue(all(math.isfinite(v) for v in command["values"]))
                        self.assertTrue(all(0 <= y <= 98 for y in command["values"][1::2]))


if __name__ == "__main__": unittest.main()
