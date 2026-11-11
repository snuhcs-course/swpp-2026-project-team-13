"""Offline validation of every imported asset and shared difficulty assignment."""
import hashlib
import json
import math
from pathlib import Path
import sys
import unittest
import zipfile

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'backend'))
from solfege.difficulty import analyze, level_for_score, CUTOFFS, VERSION
from solfege.features.musicxml import decode, read_xml
from solfege.practice_bank import timed_practice_question

CONTENT=ROOT/'backend/content';RESOURCES=ROOT/'frontend/IPadApp/IPadApp/Resources'

class PracticeBankTests(unittest.TestCase):
    def test_every_question_uses_its_actual_score_and_fixed_cutoffs(self):
        data=json.loads((CONTENT/'practice-difficulty.json').read_text(encoding='utf8'))
        self.assertEqual(data['version'],VERSION);self.assertEqual(data['cutoffs'],list(CUTOFFS))
        self.assertEqual(data,json.loads((RESOURCES/'practice-difficulty.json').read_text(encoding='utf8')))
        catalog=json.loads((CONTENT/'practice-bank-catalog.json').read_text(encoding='utf8'))
        self.assertEqual([r['metadata'] for r in catalog],json.loads((RESOURCES/'practice-bank-catalog.json').read_text(encoding='utf8')))
        manifest=json.loads((CONTENT/'engraving/manifest.json').read_text(encoding='utf8'))
        layout_audit=json.loads((CONTENT/'source/practice-bank/engraving-layout-audit.json').read_text(encoding='utf8'))
        self.assertEqual(layout_audit['bad'],0)
        existing={}
        for name in ('catalog.json','additional-practice-catalog.json','sheet-revisions.json'):
            for item in json.loads((CONTENT/name).read_text(encoding='utf8')):existing[item['metadata']['id']]=item
        catalog += list(existing.values())
        tested=set()
        for item in catalog:
            q=item['metadata'];record=data['records'].get(q['id'])
            if record is None:continue  # A duplicate remains available to old attempts.
            tested.add(q['id'])
            self.assertNotEqual(q.get('collection'),'classical')
            raw=read_xml(CONTENT/item['main_path']);result=analyze(raw,quarter_bpm=record['quarter_bpm'],reference_quarter_bpm=record['reference_quarter_bpm'])
            self.assertAlmostEqual(result['score'],record['score'],places=9,msg=q['id'])
            self.assertEqual(result['level'],record['level'])
            self.assertEqual(result['score_floor'],record['score_floor'])
            for kind in ('main','scale'):
                b=(CONTENT/item[kind+'_path']).read_bytes();asset=q['score_assets'][kind]
                self.assertEqual(hashlib.sha256(b).hexdigest(),asset['sha256'])
                self.assertEqual(len(b),asset['size_bytes'])
                if q.get('collection')=='practice_bank':
                    self.assertEqual(b,(RESOURCES/f'practice-{q["id"]}-{kind}.mxl').read_bytes())
                    with zipfile.ZipFile(CONTENT/item[kind+'_path']) as z:
                        xml=z.read('score.xml');self.assertNotIn(b'<!DOCTYPE',xml)
                    mm,ee,aa,diag=decode(xml,'verify',{})
                    self.assertEqual(len(mm),asset['measure_count']);self.assertFalse(diag)
            image=manifest['scores'][q['score_assets']['main']['sha256']]
            png=(CONTENT/'engraving'/(image['resource']+'.png')).read_bytes()
            self.assertEqual(hashlib.sha256(png).hexdigest(),image['sha256'])
            self.assertEqual(png,(RESOURCES/(image['resource']+'.pngdata')).read_bytes())
            self.assertLess(image['pixel_height']/image['pixel_width'],.41)
            if q.get('collection')=='practice_bank':
                layout=layout_audit['records'][q['id']]
                self.assertEqual(layout['staff_line_count'],10)
                self.assertEqual(layout['image_sha256'],image['sha256'])
            if image.get('style'):
                self.assertEqual(image['style_sha256'],hashlib.sha256((ROOT/'scripts/engraving'/(image['style']+'.mss')).read_bytes()).hexdigest())
        self.assertEqual(tested,set(data['records']))
        self.assertEqual({r['level'] for r in data['records'].values()},set(range(1,10)))
        self.assertEqual(sum(r['source']=='generated-1000' for r in data['records'].values()),1000)

    def test_entry_policy_at_all_supported_tempos_and_unaltered_signature_free_questions(self):
        data=json.loads((CONTENT/'practice-difficulty.json').read_text(encoding='utf8'))
        previous=json.loads((CONTENT/'difficulty-history/practice-difficulty-1.json').read_text(encoding='utf8'))
        catalog={}
        for name in ('catalog.json','additional-practice-catalog.json','sheet-revisions.json','practice-bank-catalog.json'):
            for row in json.loads((CONTENT/name).read_text(encoding='utf8')):catalog[row['metadata']['id']]=row['metadata']
        no_signature_top=[]
        for qid,r in data['records'].items():
            q=catalog[qid];k=abs(q['key_signature']['fifths']);original=json.dumps(q,sort_keys=True)
            resolved=timed_practice_question(q)
            self.assertAlmostEqual(resolved['difficulty_score'],r['score'],places=9)
            for bpm in range(resolved['tempo']['minimum_bpm'],resolved['tempo']['maximum_bpm']+1):
                varied=timed_practice_question(q,selected_bpm=bpm)
                self.assertGreaterEqual(varied['practice_level'],1 if k==0 else 2 if k==1 else 3,qid)
            self.assertEqual(json.dumps(q,sort_keys=True),original,'Stored question metadata must stay immutable')
            if k==0:
                self.assertAlmostEqual(r['score'],previous['records'][qid]['score'],places=9)
                self.assertEqual(r['level'],previous['records'][qid]['level'])
                if r['level']==9:no_signature_top.append(qid)
        self.assertGreaterEqual(len(no_signature_top),148)

    def test_inventory_accounts_for_every_source_and_keeps_exclusions_visible(self):
        audit=json.loads((CONTENT/'source/practice-bank/import-audit.json').read_text(encoding='utf8'))
        inventory=json.loads((CONTENT/'source/practice-bank/inventory.json').read_text(encoding='utf8'))
        self.assertEqual(audit['total'],len(inventory))
        self.assertEqual(audit['total'],audit['accepted']+len(audit['excluded'])+len(audit['duplicates']))
        with zipfile.ZipFile(CONTENT/'source/practice-bank/sources.zip') as z:
            self.assertIsNone(z.testzip())
            for row in inventory:
                self.assertEqual(hashlib.sha256(z.read(row['archive_path'])).hexdigest(),row['sha256'])
                if row.get('original_archive_path'):
                    self.assertEqual(hashlib.sha256(z.read(row['original_archive_path'])).hexdigest(),row['original_sha256'])

if __name__=='__main__':
    suite=unittest.defaultTestLoader.loadTestsFromName('solfege.tests_difficulty')
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(PracticeBankTests))
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
