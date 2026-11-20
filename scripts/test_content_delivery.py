"""Delivery integrity and device resource policy; no Django or image libraries."""
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from app_content_policy import RESOURCES, RUNTIME, ROOT, allowed_files, apply_policy

def read(path):return json.loads(path.read_text(encoding='utf-8'))
def sha(data):return hashlib.sha256(data).hexdigest()

class ContentDeliveryTests(unittest.TestCase):
    def test_all_server_files_are_intact_and_have_no_unbounded_paths(self):
        root=ROOT/'backend/content';manifest=read(root/'client-content-manifest.json')
        self.assertEqual(manifest['version'],1)
        self.assertLess(len(manifest['assets']),5000)
        self.assertLess(len(json.dumps(manifest['assets']).encode()),2*1024*1024)
        for name,asset in manifest['assets'].items():
            self.assertEqual(Path(name).name,name)
            record=manifest['files'][asset['sha256']];path=(root/record['path']).resolve()
            self.assertTrue(path.is_relative_to(root.resolve()))
            data=path.read_bytes()
            self.assertEqual(sha(data),asset['sha256'])
            self.assertEqual(len(data),asset['size_bytes'])
            self.assertLessEqual(len(data),8_388_608)
            self.assertEqual(data,(RESOURCES/name).read_bytes())
        memory=read(root/'drills/memory-run-v2.json')
        for source in memory['sources']:
            self.assertEqual(manifest['assets'][source['file']]['sha256'],source['sha256'])

    def test_small_demo_is_self_contained_disjoint_and_keeps_music_hashes(self):
        index=read(RESOURCES/'small-demo-index.json');keep=set(index['required_files'])
        self.assertEqual(index['question_count'],6)
        for name in keep:self.assertTrue((RESOURCES/name).is_file(),name)
        catalog=read(RESOURCES/index['files']['catalog'])
        pools=read(RESOURCES/index['files']['pools'])['records']
        self.assertEqual([pools[q['id']]['pool'] for q in catalog],['practice']*3+['exam']*3)
        engraving=read(RESOURCES/index['files']['engraving'])['scores']
        for i,q in enumerate(catalog):
            for kind in ['main','scale']:
                filename=f'excerpt-{i+1}-v2-{kind}.mxl' if i<3 else f'practice-{q["id"]}-{kind}.mxl'
                self.assertIn(filename,keep)
                self.assertEqual(sha((RESOURCES/filename).read_bytes()),q['score_assets'][kind]['sha256'])
            display=engraving[q['score_assets']['main']['sha256']]
            self.assertIn(display['resource']+'.pngdata',keep)
            self.assertEqual(sha((RESOURCES/(display['resource']+'.pngdata')).read_bytes()),display['sha256'])
            self.assertIn(q['sheet_layout']['id']+'.pngdata',keep)
        memory=read(RESOURCES/index['files']['memory-run-v2'])
        self.assertEqual(len(memory['excerpts']),20)
        self.assertEqual(len({e['sourceId'] for e in memory['excerpts']}),20)
        self.assertGreaterEqual(len([e for e in memory['excerpts'] if e['bars']==4]),4)
        self.assertGreaterEqual(len([e for e in memory['excerpts'] if e['beginnerEligible'] and e['attacks']<=5 and e['pitchRange']<=5 and e['largestInterval']<=2]),4)
        for source in memory['sources']:
            self.assertIn(source['file'],keep)
            self.assertEqual(sha((RESOURCES/source['file']).read_bytes()),source['sha256'])
        groove=read(RESOURCES/index['files']['memory-groove-v1'])
        self.assertEqual(groove['catalogSha256'],sha((RESOURCES/index['files']['memory-run-v2']).read_bytes()))
        rhythm=read(RESOURCES/index['files']['rhythm-puzzle-v3'])
        ink=read(RESOURCES/index['files']['rhythm-engraving-v3'])
        self.assertEqual(ink['catalog_sha256'],sha((RESOURCES/index['files']['rhythm-puzzle-v3']).read_bytes()))
        for level in ['beginner','intermediate','advanced']:
            self.assertGreaterEqual(sum(r['level']==level for r in rhythm['rounds']),5)
        self.assertEqual({t['id'] for t in rhythm['tiles']},set(ink['tiles']))

    def test_bundle_policy_prunes_only_known_resources_and_can_restore_full_demo(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);res=root/'Resources';res.mkdir();app=root/'Test.app';app.mkdir()
            (res/'small-demo-index.json').write_text('{"required_files":["sample.xml"]}')
            for name in ['sample.xml','full-bank.json','sori-click-v1.wav']:
                (res/name).write_text(name);shutil.copyfile(res/name,app/name)
            (app/'IPadApp').write_text('executable');(app/'drawing.pkdrawing').write_text('student')
            apply_policy(app,resources=res)
            self.assertFalse((app/'full-bank.json').exists())
            self.assertTrue((res/'full-bank.json').exists())
            self.assertTrue((app/'sample.xml').exists());self.assertTrue((app/'IPadApp').exists())
            self.assertEqual((app/'drawing.pkdrawing').read_text(),'student')
            apply_policy(app,full=True,resources=res)
            self.assertTrue((app/'full-bank.json').exists())
            self.assertEqual(read(app/'bundled-content.json')['mode'],'full-demo')

    def test_resource_reduction_and_required_runtime_files(self):
        allowed=allowed_files();source=[p for p in RESOURCES.iterdir() if p.is_file()]
        # Instrument downloads happen in CI; compare the same audio assets on both sides.
        missing=RUNTIME-{p.name for p in source}
        self.assertLessEqual(missing,{'GeneralUser-GS.sf2','instrument-bank.json','generaluser-license.txt','melody-classical-piano.sf2','melody-piano-bank.json','melody-piano-license.txt'})
        before=sum(p.stat().st_size for p in source);after=sum(p.stat().st_size for p in source if p.name in allowed)
        self.assertLess(after,before*0.1)
        self.assertNotIn('practice-bank-catalog.json',allowed)
        print(f'Content fixtures: {before/1048576:.1f} -> {after/1048576:.1f} MiB (current audio downloads excluded from both).')

if __name__=='__main__':unittest.main()
