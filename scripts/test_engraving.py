"""Validate shipped renderer outputs without installing MuseScore or changing assets."""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / "backend/content"
RESOURCES = ROOT / "frontend/IPadApp/IPadApp/Resources"
spec = importlib.util.spec_from_file_location("engraving_build", ROOT / "scripts/build_score_previews.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class EngravingTests(unittest.TestCase):
    def test_all_immutable_score_versions_resolve_to_intact_bundled_images(self):
        manifest = json.loads((CONTENT / "engraving/manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest, json.loads((RESOURCES / "engraving-manifest.json").read_text(encoding="utf-8")))
        self.assertEqual(manifest["style_sha256"],hashlib.sha256((ROOT / "scripts/engraving/compact-v1.mss").read_bytes()).hexdigest())
        expected = {i["metadata"]["score_assets"]["main"]["sha256"] for filename in ("catalog.json","catalog-v1.json","classical-catalog.json","additional-practice-catalog.json") for i in json.loads((CONTENT / filename).read_text(encoding="utf-8"))}
        self.assertEqual(set(manifest["scores"]),expected)
        style = ET.parse(ROOT / "scripts/engraving/compact-v1.mss")
        self.assertEqual(style.findtext("Style/showMeasureNumber"),"0")
        for version in ("catalog.json","catalog-v1.json","classical-catalog.json","additional-practice-catalog.json"):
            for item in json.loads((CONTENT / version).read_text(encoding="utf-8")):
                asset = manifest["scores"][item["metadata"]["score_assets"]["main"]["sha256"]]
                data = (CONTENT / "engraving" / (asset["resource"]+".png")).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(),asset["sha256"])
                self.assertEqual(len(data),asset["size_bytes"])
                self.assertEqual(struct.unpack(">II",data[16:24]),(asset["pixel_width"],asset["pixel_height"]))
                self.assertLess(asset["pixel_height"]/asset["pixel_width"],0.28 if item["metadata"]["score_assets"]["main"]["profile"]=="sori-monophonic-v3" else 0.25)
                self.assertEqual(data,(RESOURCES / (asset["resource"]+".pngdata")).read_bytes())
    def test_hash_pinned_style_has_the_same_bytes_in_a_linux_checkout(self):
        data = (ROOT / "scripts/engraving/compact-v1.mss").read_bytes()
        self.assertNotIn(b"\r",data,"Regenerate manifests from the LF stylesheet stored in Git")
        self.assertEqual(hashlib.sha256(data).hexdigest(),hashlib.sha256(data.replace(b"\r\n",b"\n")).hexdigest())

    def test_display_only_courtesy_natural_preserves_tied_notes_and_musical_content(self):
        score = ET.fromstring('''<score-partwise><part><measure number="1"><note><pitch><step>F</step><alter>1</alter><octave>4</octave></pitch><duration>480</duration><type>quarter</type><accidental>sharp</accidental></note></measure><measure number="2"><note><pitch><step>F</step><octave>4</octave></pitch><duration>480</duration><type>quarter</type></note><note><pitch><step>F</step><octave>4</octave></pitch><duration>480</duration><type>quarter</type></note></measure></part></score-partwise>''')
        signature = module.notes_signature(score)
        module.prepare(score)
        naturals = score.findall("part/measure/note/accidental")
        self.assertEqual([a.text for a in naturals],["sharp","natural"])
        self.assertEqual(naturals[1].get("cautionary"),"yes")
        self.assertEqual(module.notes_signature(score),signature)
        tied = ET.fromstring('''<score-partwise><part><measure number="1"><note><pitch><step>F</step><alter>1</alter><octave>4</octave></pitch><duration>480</duration><type>quarter</type></note></measure><measure number="2"><note><pitch><step>F</step><alter>1</alter><octave>4</octave></pitch><duration>480</duration><tie type="stop"/><type>quarter</type></note></measure></part></score-partwise>''')
        module.prepare(tied)
        self.assertEqual(tied.findall("part/measure/note/accidental"),[])

if __name__ == "__main__":
    unittest.main()
