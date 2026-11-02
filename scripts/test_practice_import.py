"""Validate exact source excerpts, selection, immutable assets and shared exam routes."""
import collections
import copy
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET
import zipfile

import import_practice_questions as build
import build_classical_questions as classical

ROOT=Path(__file__).resolve().parents[1]
CONTENT=ROOT/'backend/content'
RESOURCES=ROOT/'frontend/IPadApp/IPadApp/Resources'
CATALOG=json.loads((CONTENT/'additional-practice-catalog.json').read_text(encoding='utf-8'))
PROVENANCE=json.loads((CONTENT/'source/practice-import/provenance.json').read_text(encoding='utf-8'))


class PracticeImportTests(unittest.TestCase):
    def test_selection_is_separate_and_has_every_non_silent_pages_exercise(self):
        self.assertEqual(len(CATALOG),51)
        self.assertEqual(collections.Counter(q['metadata']['difficulty'] for q in CATALOG),{'beginner':40,'intermediate':11})
        pages=[x for x in PROVENANCE['accepted'] if x['kind']=='pages']
        self.assertEqual([x['block'] for x in pages],[1,2,3,4,5,7,8,9,10,11,12])
        self.assertEqual(PROVENANCE['excluded'],[dict(kind='pages',block=6,measures=[41,48],reason='eight_bars_of_rests')])
        raw=ET.parse(build.SOURCE/'pages-1-2.musicxml')
        self.assertTrue(all(n.find('pitch') is None for bar in raw.findall('part/measure')[40:48] for n in bar.findall('note')))
        ids=[q['metadata']['id'] for q in CATALOG]
        self.assertEqual(len(set(ids)),51)
        for filename,count in [('catalog.json',62),('classical-catalog.json',11)]:
            old=json.loads((CONTENT/filename).read_text(encoding='utf-8'))
            self.assertEqual(len(old),count)
            self.assertFalse(set(ids)&{q['metadata']['id'] for q in old})
        self.assertEqual(json.loads((RESOURCES/'additional-practice-catalog.json').read_text(encoding='utf-8')),[q['metadata'] for q in CATALOG])

    def test_all_original_notes_rhythms_and_ties_survive_without_padding_or_transposition(self):
        for info,item in zip(PROVENANCE['accepted'],CATALOG):
            with self.subTest(source=info['source_id']):
                data=(build.SOURCE/info['file']).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(),info['sha256'])
                original=ET.fromstring(data)
                notes=original.findall('part/measure/note')
                if info['kind']=='pages':
                    first,last=info['measures']; bars=original.findall('part/measure')[first-1:last]
                    notes=[n for b in bars for n in b.findall('note')]
                divisions=int(original.findtext('part/measure/attributes/divisions'))
                expected=[(n.findtext('pitch/step'),int(n.findtext('pitch/alter','0')),n.findtext('pitch/octave'),Fraction(int(n.findtext('duration')),divisions),tuple(t.get('type') for t in n.findall('tie'))) for n in notes]
                with zipfile.ZipFile(CONTENT/item['main_path']) as archive: score=ET.fromstring(archive.read('score.xml'))
                self.assertEqual(build.musical_identity(score),expected)
                classical.validate_source(score)
                self.assertEqual(len(score.findall('part/measure')),8)
                self.assertTrue(score.findall('part/measure/note/pitch'))

    def test_beginner_set_has_variety_and_excludes_trivial_and_advanced_material(self):
        selected=[q for q in PROVENANCE['accepted'] if q['kind']=='trained-ear']
        self.assertEqual(len(selected),40)
        self.assertGreaterEqual(len({q['book'] for q in selected}),8)
        self.assertGreaterEqual(len({tuple(q['meter']) for q in selected}),4)
        self.assertEqual({q['key']['mode'] for q in selected},{'major','minor'})
        self.assertGreaterEqual(len({q['key']['fifths'] for q in selected}),5)
        identities=[]
        for info in selected:
            score=build.source_score(info); f=build.features(score)
            self.assertIsNone(build.beginner_rejection(f,info['key']['fifths']))
            identities.append(repr((tuple(info['meter']),info['key'],build.musical_identity(score))))
        self.assertEqual(len(set(identities)),40)
        self.assertEqual(build.beginner_rejection(dict(notes=8,pitch_count=3,span=4,rhythms=1),0),'too_simple')
        self.assertEqual(PROVENANCE['beginner_selection']['pickups_excluded'],86)

    def test_assets_reference_scales_keyed_sheets_and_bundles_are_pinned(self):
        manifest=json.loads((CONTENT/'engraving/manifest.json').read_text(encoding='utf-8'))
        for item in CATALOG:
            q=item['metadata']; meter=q['time_signature']; key=q['key_signature']
            for kind in ['main','scale']:
                asset=q['score_assets'][kind]; data=(CONTENT/item[kind+'_path']).read_bytes()
                self.assertEqual(data,(RESOURCES/f'practice-{q["id"]}-{kind}.mxl').read_bytes())
                self.assertEqual(hashlib.sha256(data).hexdigest(),asset['sha256']); self.assertEqual(len(data),asset['size_bytes'])
                with zipfile.ZipFile(CONTENT/item[kind+'_path']) as archive: score=ET.fromstring(archive.read('score.xml'))
                self.assertEqual(classical.signature(score),(key['fifths'],key['mode']))
                self.assertEqual(len(score.findall('part/measure')),asset['measure_count'])
                for bar in score.findall('part/measure'):
                    self.assertEqual(sum(int(n.findtext('duration')) for n in bar.findall('note')),meter['numerator']*1920//meter['denominator'])
            layout=q['sheet_layout']; self.assertEqual(layout['id'],f'staff-8bars-{meter["numerator"]}-{meter["denominator"]}-key{key["fifths"]}-v3')
            png=(CONTENT/'sheets'/(layout['id']+'.png')).read_bytes()
            self.assertEqual(hashlib.sha256(png).hexdigest(),layout['template_sha256'])
            self.assertEqual(png,(RESOURCES/(layout['id']+'.pngdata')).read_bytes())
            svg=ET.parse(CONTENT/'sheets'/(layout['id']+'.svg'))
            marks=[x for x in svg.findall('{http://www.w3.org/2000/svg}path') if x.get('class')=='KeySignature']
            self.assertEqual(len(marks),abs(key['fifths'])*2)
            answer=manifest['scores'][q['score_assets']['main']['sha256']]
            self.assertEqual(answer['renderer'],'MuseScore Studio 4.6.3')
            answer_bytes=(CONTENT/'engraving'/(answer['resource']+'.png')).read_bytes()
            self.assertEqual(hashlib.sha256(answer_bytes).hexdigest(),answer['sha256'])
            self.assertEqual(answer_bytes,(RESOURCES/(answer['resource']+'.pngdata')).read_bytes())

    def test_tuplet_display_uses_the_existing_native_profile(self):
        saw_tuplet=False
        for item in CATALOG:
            with zipfile.ZipFile(CONTENT/item['main_path']) as archive: root=ET.fromstring(archive.read('score.xml'))
            for tuplet in root.findall('part/measure/note/notations/tuplet'):
                saw_tuplet=True
                self.assertEqual(list(tuplet),[])
                self.assertIn(tuplet.get('type'),['start','stop'])
            for note in root.findall('part/measure/note'):
                ties=sorted(t.get('type') for t in note.findall('tie'))
                drawn=sorted(t.get('type') for t in note.findall('notations/tied'))
                if drawn: self.assertEqual(ties,drawn)
        self.assertTrue(saw_tuplet)


if __name__=='__main__': unittest.main(verbosity=2)
