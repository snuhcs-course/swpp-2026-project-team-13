"""Verify the v5 sheets (aligned barlines, S9 engraving) and their immutable publication."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import unittest

ROOT=Path(__file__).resolve().parents[1]
CONTENT=ROOT/'backend/content'
RESOURCES=ROOT/'frontend/IPadApp/IPadApp/Resources'
spec=importlib.util.spec_from_file_location('build_v5',ROOT/'scripts/build_sheet_revisions_v5.py')
build=importlib.util.module_from_spec(spec);spec.loader.exec_module(build)
REVISIONS=json.loads((CONTENT/'sheet-revisions-v5.json').read_text(encoding='utf-8'))


def previous_versions():
    latest={}
    for filename in build.CATALOGS:
        for item in json.loads((CONTENT/filename).read_text(encoding='utf-8')):
            qid=item['metadata']['id']
            if qid not in latest or item['metadata']['version']>latest[qid]['metadata']['version']:
                latest[qid]=item
    return latest


class SheetRevisionV5Tests(unittest.TestCase):
    def test_every_current_v4_question_gets_one_new_version_with_only_the_sheet_changed(self):
        before=previous_versions()
        v4={qid for qid,item in before.items() if item['metadata']['sheet_layout']['id'].endswith('-v4')}
        self.assertEqual({q['metadata']['id'] for q in REVISIONS},v4)
        self.assertEqual(len(REVISIONS),len(v4))
        self.assertEqual(json.loads((RESOURCES/'sheet-revisions-v5.json').read_text(encoding='utf-8')),[q['metadata'] for q in REVISIONS])
        for revision in REVISIONS:
            q=revision['metadata']; old=before[q['id']]; restored=copy.deepcopy(revision)
            self.assertEqual(q['version'],old['metadata']['version']+1)
            restored['metadata']['version']-=1
            restored['metadata']['sheet_layout']=old['metadata']['sheet_layout']
            for kind in ['main','scale']:
                self.assertIn('/versions/'+str(q['version'])+'/',q['score_assets'][kind]['url'])
                restored['metadata']['score_assets'][kind]['url']=old['metadata']['score_assets'][kind]['url']
            self.assertEqual(restored,old)

    def test_barlines_line_up_and_the_canvas_keeps_its_export_coordinates(self):
        for item in REVISIONS:
            q=item['metadata']; layout=q['sheet_layout']; meter=q['time_signature']; fifths=q['key_signature']['fifths']
            self.assertEqual(layout['id'],f'staff-8bars-{meter["numerator"]}-{meter["denominator"]}-key{fifths}-v5')
            self.assertEqual((layout['logical_width'],layout['logical_height'],layout['pixel_width'],layout['pixel_height'],layout['export_scale']),(1330,846,2660,1692,2))
            first,second=layout['systems']
            self.assertEqual(first['staff_line_y'],[164,176,188,200,212])
            self.assertEqual(second['staff_line_y'],[340,352,364,376,388])
            self.assertEqual(layout['display_height'],574)
            self.assertEqual(first['barline_x'],second['barline_x'])
            bars=first['barline_x']
            self.assertEqual((bars[0],bars[-1]),(54,1276))
            widths=[b-a for a,b in zip(bars[1:],bars[2:])]
            self.assertLessEqual(max(widths)-min(widths),1)
            data=(CONTENT/'sheets'/(layout['id']+'.png')).read_bytes()
            self.assertEqual(struct.unpack('>II',data[16:24]),(2660,1692))
            self.assertEqual(hashlib.sha256(data).hexdigest(),layout['template_sha256'])
            self.assertEqual(data,(RESOURCES/(layout['id']+'.pngdata')).read_bytes())
            self.assertEqual(json.loads((CONTENT/'sheets'/(layout['id']+'.layout.json')).read_text(encoding='utf-8')),layout)

    def test_grading_boxes_follow_the_v5_coordinates(self):
        spec=importlib.util.spec_from_file_location('sheet_assessment',ROOT/'backend/solfege/assessment.py')
        assessment=importlib.util.module_from_spec(spec);spec.loader.exec_module(assessment)
        layout=REVISIONS[0]['metadata']['sheet_layout']
        value=dict(status='completed',recognized_musicxml='<score-partwise/>',score=100,pitch_accuracy=100,rhythm_accuracy=100,feedback=dict(summary='ok',recommendations=[]),annotations=[dict(type='pitch_error',measure=6,message='check'),dict(type='pitch_error',measure=2,message='check')])
        lower,upper=assessment.validate_result(value,layout)['annotations']
        self.assertAlmostEqual(lower['bbox']['y'],(340-90)/846)
        self.assertEqual((lower['bbox']['x'],lower['bbox']['width']),(upper['bbox']['x'],upper['bbox']['width']))


if __name__=='__main__':unittest.main(verbosity=2)
