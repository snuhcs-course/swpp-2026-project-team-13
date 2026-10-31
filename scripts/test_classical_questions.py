"""Offline content regression: strict source bars, keys, scales, templates and MuseScore answers."""
import copy
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import struct
import unittest
import xml.etree.ElementTree as ET
import zipfile

import build_classical_questions as build

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT/"backend/content"
RESOURCES = ROOT/"frontend/IPadApp/IPadApp/Resources"
CATALOG = json.loads((CONTENT/"classical-catalog.json").read_text(encoding="utf-8"))
PROVENANCE = json.loads((CONTENT/"source/classical/provenance.json").read_text(encoding="utf-8"))


class ClassicalQuestionTests(unittest.TestCase):
    def test_separate_catalog_does_not_replace_any_of_the_62_exercises(self):
        practice = json.loads((CONTENT/"catalog.json").read_text(encoding="utf-8"))
        self.assertEqual(len(practice),62)
        self.assertEqual(len(CATALOG),11)
        self.assertFalse({q["metadata"]["id"] for q in practice} & {q["metadata"]["id"] for q in CATALOG})
        self.assertEqual(json.loads((RESOURCES/"classical-catalog.json").read_text(encoding="utf-8")),[q["metadata"] for q in CATALOG])
        self.assertEqual(json.loads((RESOURCES/"practice-catalog.json").read_text(encoding="utf-8")),[q["metadata"] for q in practice])
        self.assertEqual(len({q["metadata"]["composer"] for q in CATALOG}),7)

    def test_every_question_preserves_all_eight_full_original_bars(self):
        for info,item in zip(PROVENANCE["accepted"],CATALOG):
            with self.subTest(title=info["title"]):
                data = (CONTENT/"source/classical"/info["file"]).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(),info["sha256"])
                original = ET.fromstring(data); meter,fifths,mode = build.validate_source(original)
                with zipfile.ZipFile(CONTENT/item["main_path"]) as archive:
                    self.assertEqual(archive.namelist(),["mimetype","META-INF/container.xml","score.xml"])
                    score = ET.fromstring(archive.read("score.xml"))
                self.assertEqual(build.musical_notes(original),build.musical_notes(score))
                self.assertEqual(build.signature(score),(fifths,mode))
                self.assertEqual(len(score.findall("part/measure")),8)
                self.assertEqual(item["metadata"]["time_signature"],dict(numerator=meter[0],denominator=meter[1]))
                self.assertTrue(all(b.get("implicit") != "yes" for b in score.findall("part/measure")))
                self.assertEqual({x.tag for x in score.findall(".//notations/*")} - {"tied","tuplet"},set())

    def test_pickups_padding_cropping_and_external_ties_are_rejected(self):
        score = ET.parse(CONTENT/"source/classical"/PROVENANCE["accepted"][0]["file"]).getroot()
        cases = []
        pickup = copy.deepcopy(score); pickup.find("part/measure").set("implicit","yes"); cases.append(pickup)
        short = copy.deepcopy(score); bar = short.find("part/measure"); bar.remove(bar.findall("note")[-1]); cases.append(short)
        long = copy.deepcopy(score); part = long.find("part"); part.append(copy.deepcopy(part.findall("measure")[-1])); cases.append(long)
        external = copy.deepcopy(score); ET.SubElement(external.find("part/measure/note"),"tie",type="stop"); cases.append(external)
        for candidate in cases:
            with self.assertRaises(AssertionError): build.validate_source(candidate)

    def test_scale_pitch_spelling_key_and_meter_match_each_question(self):
        for item in CATALOG:
            q = item["metadata"]; key = q["key_signature"]; meter=q["time_signature"]
            with zipfile.ZipFile(CONTENT/item["scale_path"]) as archive: score=ET.fromstring(archive.read("score.xml"))
            self.assertEqual(build.signature(score),(key["fifths"],key["mode"]))
            attacks=[n for n in score.findall("part/measure/note") if not any(t.get("type")=="stop" for t in n.findall("tie"))]
            self.assertEqual(len(attacks),15)
            midi=[(int(n.findtext("pitch/octave"))+1)*12+dict(C=0,D=2,E=4,F=5,G=7,A=9,B=11)[n.findtext("pitch/step")]+int(n.findtext("pitch/alter","0")) for n in attacks]
            intervals=[b-a for a,b in zip(midi[:8],midi[1:8])]
            self.assertEqual(intervals,[2,1,2,2,1,2,2] if key["mode"]=="minor" else [2,2,1,2,2,2,1])
            self.assertEqual(midi,midi[:8]+list(reversed(midi[:7])))
            ticks=meter["numerator"]*1920//meter["denominator"]
            for bar in score.findall("part/measure"):
                self.assertEqual(sum(int(n.findtext("duration")) for n in bar.findall("note")),ticks)

    def test_template_signatures_match_the_png_and_both_systems(self):
        for item in CATALOG:
            q=item["metadata"]; key=q["key_signature"]; meter=q["time_signature"]; layout=q["sheet_layout"]
            self.assertEqual(layout["id"],f'staff-8bars-{meter["numerator"]}-{meter["denominator"]}-key{key["fifths"]}-v3')
            png=(CONTENT/"sheets"/(layout["id"]+".png")).read_bytes()
            self.assertEqual(struct.unpack(">II",png[16:24]),(2660,1692))
            self.assertEqual(hashlib.sha256(png).hexdigest(),layout["template_sha256"])
            self.assertEqual(png,(RESOURCES/(layout["id"]+".pngdata")).read_bytes())
            svg=ET.parse(CONTENT/"sheets"/(layout["id"]+".svg")); texts=svg.findall("{http://www.w3.org/2000/svg}text")
            marks=[p for p in svg.findall("{http://www.w3.org/2000/svg}path") if p.get("class")=="KeySignature"]
            self.assertEqual(len(marks),2*abs(key["fifths"]))
            self.assertEqual([t.text for t in texts if t.get("font-family")=="Times New Roman"],[str(meter["numerator"]),str(meter["denominator"])])
            positions=[0,18,-6,12,30,6,24] if key["fifths"]>0 else [24,6,30,12,36,18,42]
            for system,y in enumerate((164,499)):
                signatures=[p for p in marks if p.get("data-system")==str(system)]
                self.assertEqual([float(p.get("data-pitch-y")) for p in signatures],[y+offset for offset in positions[:abs(key["fifths"])]])
                self.assertTrue(all(p.get("data-fifths")==str(key["fifths"]) for p in signatures))

    def test_all_main_scale_and_musescore_bytes_are_pinned_and_bundled(self):
        manifest=json.loads((CONTENT/"engraving/manifest.json").read_text(encoding="utf-8"))
        for item in CATALOG:
            q=item["metadata"]
            for kind,asset in q["score_assets"].items():
                data=(CONTENT/item[kind+"_path"]).read_bytes()
                self.assertEqual(data,(RESOURCES/f'classical-{q["id"]}-{kind}.mxl').read_bytes())
                self.assertEqual((len(data),hashlib.sha256(data).hexdigest()),(asset["size_bytes"],asset["sha256"]))
            image=manifest["scores"][q["score_assets"]["main"]["sha256"]]
            self.assertEqual(image["renderer"],"MuseScore Studio 4.6.3")
            png=(CONTENT/"engraving"/(image["resource"]+".png")).read_bytes()
            self.assertEqual(hashlib.sha256(png).hexdigest(),image["sha256"])
            self.assertEqual(png,(RESOURCES/(image["resource"]+".pngdata")).read_bytes())

    def test_new_meters_keep_full_scale_and_countin_durations(self):
        import importlib.util
        spec=importlib.util.spec_from_file_location("playback",ROOT/"backend/sori/playback.py")
        playback=importlib.util.module_from_spec(spec); spec.loader.exec_module(playback)
        for meter,count,beat,bpm in [((2,2),2,"half",96),((3,8),5,"dotted_quarter",82.5)]:
            data,bars=build.scale(meter,2,"major"); self.assertEqual(bars,count)
            import io
            with zipfile.ZipFile(io.BytesIO(data)) as z: score=ET.fromstring(z.read("score.xml"))
            self.assertTrue(all(sum(int(n.findtext("duration")) for n in bar.findall("note"))==meter[0]*1920//meter[1] for bar in score.findall("part/measure")))
            plan=playback.make_playback_plan(dict(time_signature=dict(numerator=meter[0],denominator=meter[1]),score_assets=dict(scale=dict(measure_count=bars))))
            self.assertEqual((plan["tempo"]["beat_unit"],plan["tempo_bpm"]),(beat,bpm))
            self.assertEqual(plan["count_in"]["beats_per_measure"]*1920//plan["count_in"]["beat_unit"],meter[0]*1920//meter[1])

    def test_listening_downloads_are_the_exact_exam_xml(self):
        library=json.loads((ROOT/"classical-library/library-data.json").read_text(encoding="utf-8"))
        self.assertEqual(len(library["items"]),len(CATALOG))
        for preview,item in zip(library["items"],CATALOG):
            with zipfile.ZipFile(CONTENT/item["main_path"]) as archive:
                self.assertEqual(preview["xml"],archive.read("score.xml").decode("utf-8"))
            self.assertEqual(preview["composer"],item["metadata"]["composer"])
            self.assertEqual(preview["originalMeasures"],8)
            self.assertEqual(preview["xml"],(ROOT/"classical-library/xml"/preview["file"]).read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
