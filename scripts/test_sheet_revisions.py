"""Verify compact geometry and immutable sheet publication without a DB."""
import collections
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import unittest
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
CONTENT=ROOT/'backend/content'
RESOURCES=ROOT/'frontend/IPadApp/IPadApp/Resources'
REVISIONS=json.loads((CONTENT/'sheet-revisions.json').read_text(encoding='utf-8'))
ORIGINALS={q['metadata']['id']:q for filename in ['catalog.json','classical-catalog.json','additional-practice-catalog.json'] for q in json.loads((CONTENT/filename).read_text(encoding='utf-8'))}


class SheetRevisionTests(unittest.TestCase):
    def test_only_sheet_and_version_change_for_all_124_current_questions(self):
        self.assertEqual(len(REVISIONS),124)
        self.assertEqual(len({q['metadata']['id'] for q in REVISIONS}),124)
        self.assertEqual(json.loads((RESOURCES/'sheet-revisions.json').read_text(encoding='utf-8')),[q['metadata'] for q in REVISIONS])
        for revision in REVISIONS:
            q=revision['metadata']; old=ORIGINALS[q['id']]; restored=copy.deepcopy(revision)
            restored['metadata']['version']-=1
            restored['metadata']['sheet_layout']=old['metadata']['sheet_layout']
            for kind in ['main','scale']:
                restored['metadata']['score_assets'][kind]['url']=old['metadata']['score_assets'][kind]['url']
                self.assertIn('/versions/'+str(q['version'])+'/',q['score_assets'][kind]['url'])
                self.assertEqual(hashlib.sha256((CONTENT/revision[kind+'_path']).read_bytes()).hexdigest(),q['score_assets'][kind]['sha256'])
            self.assertEqual(restored,old)
        self.assertEqual(collections.Counter(q['metadata']['version'] for q in REVISIONS),{3:62,2:62})

    def test_compact_staves_keep_canonical_export_coordinates_and_key_signatures(self):
        for item in REVISIONS:
            q=item['metadata']; layout=q['sheet_layout']; meter=q['time_signature']; fifths=q['key_signature']['fifths']
            self.assertEqual(layout['id'],f'staff-8bars-{meter["numerator"]}-{meter["denominator"]}-key{fifths}-v4')
            self.assertEqual((layout['logical_width'],layout['logical_height'],layout['pixel_width'],layout['pixel_height']),(1330,846,2660,1692))
            self.assertEqual(layout['display_height'],620)
            self.assertEqual(layout['systems'][0]['staff_line_y'],[164,176,188,200,212])
            self.assertEqual(layout['systems'][1]['staff_line_y'],[386,398,410,422,434])
            self.assertEqual(layout['systems'][1]['staff_line_y'][0]-layout['systems'][0]['staff_line_y'][0],222)
            data=(CONTENT/'sheets'/(layout['id']+'.png')).read_bytes()
            self.assertEqual(struct.unpack('>II',data[16:24]),(2660,1692))
            self.assertEqual(hashlib.sha256(data).hexdigest(),layout['template_sha256'])
            self.assertEqual(data,(RESOURCES/(layout['id']+'.pngdata')).read_bytes())
            svg=ET.parse(CONTENT/'sheets'/(layout['id']+'.svg'))
            paths=svg.findall('{http://www.w3.org/2000/svg}path')
            self.assertEqual(len([p for p in paths if p.get('class')=='KeySignature']),abs(fifths)*2)
            endings=[p for p in paths if p.get('class')=='FinalBarline']
            self.assertEqual([p.get('d') for p in endings],['M1267 386v48','M1276 386v48'])
            self.assertEqual([p.get('stroke-width') for p in endings],['1.5','4.5'])
            self.assertTrue(all(p.get('data-system')=='1' for p in endings))

    def test_old_and_new_templates_remain_available_and_grading_uses_the_new_coordinates(self):
        spec=importlib.util.spec_from_file_location('sheet_assessment',ROOT/'backend/sori/assessment.py')
        assessment=importlib.util.module_from_spec(spec);spec.loader.exec_module(assessment)
        for item in REVISIONS:
            q=item['metadata']; old=ORIGINALS[q['id']]['metadata']['sheet_layout']
            self.assertEqual(hashlib.sha256((CONTENT/'sheets'/(old['id']+'.png')).read_bytes()).hexdigest(),old['template_sha256'])
        value=dict(status='completed',recognized_musicxml='<score-partwise/>',score=100,pitch_accuracy=100,rhythm_accuracy=100,feedback=dict(summary='ok',recommendations=[]),annotations=[dict(type='pitch_error',measure=5,message='check')])
        result=assessment.validate_result(value,REVISIONS[0]['metadata']['sheet_layout'])
        self.assertAlmostEqual(result['annotations'][0]['bbox']['y'],(386-90)/846)


if __name__=='__main__':unittest.main(verbosity=2)
