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
        spec=importlib.util.spec_from_file_location("playback",ROOT/"backend/solfege/playback.py")
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


class BrahmsImportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog=json.loads((CONTENT/'brahms-catalog.json').read_text(encoding='utf-8'))
        cls.provenance=json.loads((CONTENT/'source/brahms/provenance.json').read_text(encoding='utf-8'))

    def test_complete_source_bars_preserve_every_pitch_duration_and_tie(self):
        from import_practice_questions import musical_identity
        source=CONTENT/'source/brahms'
        self.assertEqual(hashlib.sha256((source/'brahms.mscz').read_bytes()).hexdigest(),self.provenance['source_sha256'])
        raw=(source/'brahms.musicxml').read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(),self.provenance['xml_sha256'])
        original=ET.fromstring(raw);bars=original.findall('part/measure')
        self.assertEqual(len(self.catalog),10)
        self.assertEqual([i['block'] for i in self.provenance['accepted']],[1,2,3,4,5,6,7,9,10,11])
        self.assertEqual(self.provenance['excluded'],[
            dict(block=8,measures=[57,64],reason='unsupported_grace_notes'),
            dict(block=12,measures=[89,96],reason='all_rests'),
            dict(block=13,measures=[97,104],reason='all_rests'),
            dict(block=14,measures=[105,106],reason='all_rests')])
        for info,item in zip(self.provenance['accepted'],self.catalog):
            with zipfile.ZipFile(CONTENT/item['main_path']) as z:score=ET.fromstring(z.read('score.xml'))
            classical=ET.fromstring((source/info['file']).read_bytes())
            self.assertEqual(hashlib.sha256((source/info['file']).read_bytes()).hexdigest(),info['sha256'])
            self.assertEqual(musical_identity(score),musical_identity(classical))
            # Compare published note content against the full user source, not
            # merely against an already-normalized import.
            selected=ET.Element('score-partwise');part=ET.SubElement(selected,'part')
            for b in bars[info['measures'][0]-1:info['measures'][1]]:part.append(copy.deepcopy(b))
            attrs=part.find('measure/attributes')
            if attrs is None:attrs=ET.SubElement(part.find('measure'),'attributes')
            if attrs.find('divisions') is None:ET.SubElement(attrs,'divisions').text=original.findtext('part/measure/attributes/divisions')
            self.assertEqual(musical_identity(score),musical_identity(selected))
            self.assertEqual(len(score.findall('part/measure')),8)
            build.validate_source(score)

    def test_reviewed_modes_drive_actual_full_diatonic_scale_notes(self):
        expected={1:(2,'major','D'),2:(2,'minor','B'),3:(1,'minor','E'),4:(1,'minor','E'),5:(4,'major','E'),6:(0,'major','C'),7:(2,'major','D'),9:(2,'major','D'),10:(0,'major','C'),11:(-1,'major','F')}
        for info,item in zip(self.provenance['accepted'],self.catalog):
            q=item['metadata'];key=q['key_signature']
            self.assertEqual((key['fifths'],key['mode'],key['tonic']),expected[info['block']])
            if info['block'] in (3,6):self.assertEqual(info['mode_source'],'user_confirmed')
            with zipfile.ZipFile(CONTENT/item['scale_path']) as z:score=ET.fromstring(z.read('score.xml'))
            self.assertEqual(build.signature(score),(key['fifths'],key['mode']))
            notes=[n for n in score.findall('part/measure/note') if not any(t.get('type')=='stop' for t in n.findall('tie'))]
            midi=[(int(n.findtext('pitch/octave'))+1)*12+dict(C=0,D=2,E=4,F=5,G=7,A=9,B=11)[n.findtext('pitch/step')]+int(n.findtext('pitch/alter','0')) for n in notes]
            self.assertEqual(len(midi),15)
            self.assertEqual(notes[0].findtext('pitch/step'),key['tonic'][0])
            self.assertEqual([b-a for a,b in zip(midi[:8],midi[1:8])],[2,1,2,2,1,2,2] if key['mode']=='minor' else [2,2,1,2,2,2,1])
            self.assertEqual(midi,midi[:8]+list(reversed(midi[:7])))

    def test_bundled_catalog_assets_keyed_compact_sheets_and_four_plus_four_answers(self):
        self.assertEqual(json.loads((RESOURCES/'brahms-catalog.json').read_text(encoding='utf-8')),[i['metadata'] for i in self.catalog])
        manifest=json.loads((CONTENT/'engraving/manifest.json').read_text(encoding='utf-8'))
        existing={i['metadata']['id'] for name in ['catalog.json','classical-catalog.json','additional-practice-catalog.json'] for i in json.loads((CONTENT/name).read_text(encoding='utf-8'))}
        self.assertFalse(existing & {i['metadata']['id'] for i in self.catalog})
        for item in self.catalog:
            q=item['metadata'];layout=q['sheet_layout']
            for kind,asset in q['score_assets'].items():
                data=(CONTENT/item[kind+'_path']).read_bytes()
                self.assertEqual((len(data),hashlib.sha256(data).hexdigest()),(asset['size_bytes'],asset['sha256']))
                self.assertEqual(data,(RESOURCES/f'classical-{q["id"]}-{kind}.mxl').read_bytes())
            png=(CONTENT/'sheets'/(layout['id']+'.png')).read_bytes()
            self.assertEqual(layout['display_height'],620);self.assertEqual(layout['systems'][1]['staff_line_y'][0],386)
            self.assertEqual(hashlib.sha256(png).hexdigest(),layout['template_sha256'])
            self.assertEqual(png,(RESOURCES/(layout['id']+'.pngdata')).read_bytes())
            image=manifest['scores'][q['score_assets']['main']['sha256']]
            png=(CONTENT/'engraving'/(image['resource']+'.png')).read_bytes()
            self.assertEqual(image['renderer'],'MuseScore Studio 4.6.3')
            self.assertEqual(hashlib.sha256(png).hexdigest(),image['sha256'])
            self.assertEqual(png,(RESOURCES/(image['resource']+'.pngdata')).read_bytes())
            self.assertEqual(hashlib.sha256((ROOT/'scripts/engraving'/(image['style']+'.mss')).read_bytes()).hexdigest(),image['style_sha256'])
            svg=ET.parse(CONTENT/'engraving'/(image['resource']+'.svg'))
            staff=[e for e in svg.getroot() if e.get('class')=='StaffLines']
            self.assertEqual(len(staff),10,'Exactly two staves, not an overflow page')

    def test_new_meters_have_complete_countin_and_scale_and_duration(self):
        import importlib.util
        spec=importlib.util.spec_from_file_location('playback',ROOT/'backend/solfege/playback.py')
        playback=importlib.util.module_from_spec(spec);spec.loader.exec_module(playback)
        found=set()
        for item in self.catalog:
            q=item['metadata'];meter=q['time_signature'];key=(meter['numerator'],meter['denominator'])
            if key not in ((3,2),(6,4)):continue
            found.add(key);plan=playback.make_playback_plan(q)
            self.assertEqual(plan['tempo_bpm'],96)
            self.assertEqual(plan['count_in']['beats_per_measure']*1920//plan['count_in']['beat_unit'],2880)
            self.assertEqual(playback.timed_question(q)['recommended_duration_seconds'],489)
            with zipfile.ZipFile(CONTENT/item['scale_path']) as z:score=ET.fromstring(z.read('score.xml'))
            self.assertEqual(len(score.findall('part/measure')),2)
            for bar in score.findall('part/measure'):
                self.assertEqual(sum(int(n.findtext('duration')) for n in bar.findall('note')),2880)
        self.assertEqual(found,{(3,2),(6,4)})


if __name__ == "__main__":
    unittest.main()
