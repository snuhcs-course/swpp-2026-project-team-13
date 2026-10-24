"""Independent checks against original MusicXML. No Django, network or paid API needed."""
import hashlib
import json
from fractions import Fraction
from pathlib import Path
import struct
import unittest
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / "backend" / "content"
CATALOG = json.loads((CONTENT / "catalog.json").read_text(encoding="utf-8"))
SOURCES = ["lead_sheet_p1_01-08.xml", "lead_sheet_p1_09-16.xml", "lead_sheet_p1_17-24.xml"]

def musical_note(note):
    # Ignore spacing/stem direction but retain every musically meaningful item in these source files.
    return (note.find("rest") is not None, note.findtext("pitch/step"), note.findtext("pitch/alter", "0"), note.findtext("pitch/octave"), int(note.findtext("duration")), note.findtext("type"), len(note.findall("dot")), tuple(x.attrib.get("type") for x in note.findall("tie")), tuple((x.tag,x.text.strip()) for x in note.findall("time-modification/*")), tuple((x.attrib.get("number","1"),x.text.strip()) for x in note.findall("beam")))

class ContentTests(unittest.TestCase):
    def test_original_notes_and_all_three_meters_are_preserved(self):
        self.assertEqual(len(CATALOG),3)
        for item, filename, meter in zip(CATALOG,SOURCES,[(6,8),(4,4),(3,4)]):
            original = ET.fromstring((CONTENT / "source" / filename).read_bytes())
            with zipfile.ZipFile(CONTENT / item["main_path"]) as archive:
                self.assertEqual(archive.namelist(),["mimetype","META-INF/container.xml","score.xml"])
                self.assertIsNone(archive.testzip())
                data=archive.read("score.xml")
                self.assertNotIn(b"<!DOCTYPE",data)
                score=ET.fromstring(data)
            self.assertEqual([musical_note(n) for n in original.findall("part/measure/note")],[musical_note(n) for n in score.findall("part/measure/note")])
            self.assertEqual((int(score.findtext("part/measure/attributes/time/beats")),int(score.findtext("part/measure/attributes/time/beat-type"))),meter)
            self.assertEqual(len(score.findall("part/measure")),8)

    def test_all_bars_and_tuplet_durations_are_exact(self):
        bases={"whole":1920,"half":960,"quarter":480,"eighth":240,"16th":120}
        for item in CATALOG:
            meter=item["metadata"]["time_signature"]
            expected=meter["numerator"]*480*4//meter["denominator"]
            for kind in ("main","scale"):
                with zipfile.ZipFile(CONTENT / item[f"{kind}_path"]) as archive:
                    score=ET.fromstring(archive.read("score.xml"))
                for bar in score.findall("part/measure"):
                    self.assertEqual(sum(int(n.findtext("duration")) for n in bar.findall("note")),expected)
                    for note in bar.findall("note"):
                        duration=Fraction(bases[note.findtext("type")])
                        for dot in range(len(note.findall("dot"))):
                            duration+=Fraction(bases[note.findtext("type")],2**(dot+1))
                        mod=note.find("time-modification")
                        if mod is not None:
                            duration*=Fraction(int(mod.findtext("normal-notes")),int(mod.findtext("actual-notes")))
                        self.assertEqual(duration,int(note.findtext("duration")))

    def test_asset_and_template_hashes_match_exact_bundled_bytes(self):
        resources=ROOT / "frontend" / "IPadApp" / "IPadApp" / "Resources"
        for index,item in enumerate(CATALOG,1):
            for kind,asset in item["metadata"]["score_assets"].items():
                data=(CONTENT / item[f"{kind}_path"]).read_bytes()
                self.assertEqual(len(data),asset["size_bytes"])
                self.assertEqual(hashlib.sha256(data).hexdigest(),asset["sha256"])
                self.assertEqual(data,(resources / f"excerpt-{index}-{kind}.mxl").read_bytes())
            layout=item["metadata"]["sheet_layout"]
            png=(CONTENT / "sheets" / (layout["id"]+".png")).read_bytes()
            self.assertEqual(hashlib.sha256(png).hexdigest(),layout["template_sha256"])
            self.assertEqual(struct.unpack(">II",png[16:24]),(2660,1692))
            self.assertEqual(png[24],8)
            self.assertEqual(png,(resources / (layout["id"]+".pngdata")).read_bytes())

if __name__ == "__main__":
    unittest.main(verbosity=2)
