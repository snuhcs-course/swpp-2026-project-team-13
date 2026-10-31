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
        self.assertEqual(len(CATALOG),62)
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
        bases={"whole":1920,"half":960,"quarter":480,"eighth":240,"16th":120,"32nd":60}
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
                self.assertEqual(data,(resources / f"excerpt-{index}-v2-{kind}.mxl").read_bytes())
            layout=item["metadata"]["sheet_layout"]
            png=(CONTENT / "sheets" / (layout["id"]+".png")).read_bytes()
            self.assertEqual(hashlib.sha256(png).hexdigest(),layout["template_sha256"])
            self.assertEqual(struct.unpack(">II",png[16:24]),(2660,1692))
            self.assertEqual(png[24],8)
            self.assertEqual(png,(resources / (layout["id"]+".pngdata")).read_bytes())

    def test_scale_is_the_exact_fifteen_note_up_and_down_sequence(self):
        expected=[("C","4"),("D","4"),("E","4"),("F","4"),("G","4"),("A","4"),("B","4"),("C","5"),("B","4"),("A","4"),("G","4"),("F","4"),("E","4"),("D","4"),("C","4")]
        for item in CATALOG:
            with zipfile.ZipFile(CONTENT / item["scale_path"]) as archive:
                score=ET.fromstring(archive.read("score.xml"))
            notes=score.findall("part/measure/note")
            attacks = [n for n in notes if not any(t.get("type")=="stop" for t in n.findall("tie"))]
            self.assertEqual([(n.findtext("pitch/step"),n.findtext("pitch/octave")) for n in attacks],expected)
            self.assertTrue(all(n.findtext("duration")=="240" for n in attacks[:-1]))
            self.assertEqual(len(score.findall("part/measure")),item["metadata"]["score_assets"]["scale"]["measure_count"])
            self.assertEqual(item["metadata"]["version"],2)

    def test_naver_final_transcriptions_preserve_notes_rests_ties_and_accidentals(self):
        provenance=json.loads((CONTENT / "source/naver/provenance.json").read_text(encoding="utf-8"))
        resources=ROOT / "frontend/IPadApp/IPadApp/Resources"
        self.assertEqual(json.loads((resources / "practice-catalog.json").read_text(encoding="utf-8")),[i["metadata"] for i in CATALOG])
        self.assertEqual(len({i["metadata"]["id"] for i in CATALOG}),62)
        meters=set()
        for number,item in enumerate(CATALOG[3:],1):
            with self.subTest(question=number):
                filename=f"Q{number:03}.musicxml"
                data=(CONTENT / "source/naver" / filename).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(),provenance["questions"][filename]["sha256"])
                original=ET.fromstring(data)
                divisions=int(original.findtext("part/measure/attributes/divisions"))
                with zipfile.ZipFile(CONTENT / item["main_path"]) as archive:
                    score=ET.fromstring(archive.read("score.xml"))
                source_notes=original.findall("part/measure/note")
                built_notes=score.findall("part/measure/note")
                self.assertEqual(len(source_notes),len(built_notes))
                for source_note,note in zip(source_notes,built_notes):
                    expected=list(musical_note(source_note));expected[4]=expected[4]*480//divisions
                    self.assertEqual(tuple(expected),musical_note(note))
                    self.assertEqual(source_note.findtext("accidental"),note.findtext("accidental"))
                    self.assertEqual([(t.tag,sorted(t.attrib.items())) for t in source_note.findall("notations/*")],[(t.tag,sorted(t.attrib.items())) for t in note.findall("notations/*")])
                meter=item["metadata"]["time_signature"]
                self.assertEqual((str(meter["numerator"]),str(meter["denominator"])),(original.findtext("part/measure/attributes/time/beats"),original.findtext("part/measure/attributes/time/beat-type")))
                meters.add((meter["numerator"],meter["denominator"]))
                self.assertEqual(item["metadata"]["key_signature"]["mode"],"unspecified")
        self.assertEqual(meters,{(2,4),(3,4),(4,4),(6,8),(7,8),(9,8),(12,8)})

    def test_all_ties_join_contiguous_equal_pitches_and_close(self):
        for item in CATALOG:
            for kind in ("main","scale"):
                with zipfile.ZipFile(CONTENT / item[f"{kind}_path"]) as archive:
                    score=ET.fromstring(archive.read("score.xml"))
                opened=None
                for note in score.findall("part/measure/note"):
                    pitch=(note.findtext("pitch/step"),note.findtext("pitch/alter","0"),note.findtext("pitch/octave"))
                    ties=[t.get("type") for t in note.findall("tie")]
                    self.assertEqual("stop" in ties,opened is not None)
                    if opened is not None:
                        self.assertEqual(pitch,opened)
                    opened=pitch if "start" in ties else None
                self.assertIsNone(opened)

    def test_original_v1_files_remain_available_with_the_original_hashes(self):
        original=json.loads((CONTENT / "catalog-v1.json").read_text(encoding="utf-8"))
        for item in original:
            for kind in ("main","scale"):
                data=(CONTENT / item[f"{kind}_path"]).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(),item["metadata"]["score_assets"][kind]["sha256"])

if __name__ == "__main__":
    unittest.main(verbosity=2)
