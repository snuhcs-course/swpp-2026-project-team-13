"""Integrity, immutable revision and geometry checks for S14's actual shipped assets."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import unittest
import zlib

ROOT=Path(__file__).resolve().parents[1]
CONTENT=ROOT/'backend/content'
RESOURCES=ROOT/'frontend/IPadApp/IPadApp/Resources'
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def sha(data):return hashlib.sha256(data).hexdigest()
def validate_png(data):
    assert data[:8]==b'\x89PNG\r\n\x1a\n'
    at=8;ended=False
    while at<len(data):
        size=struct.unpack('>I',data[at:at+4])[0];tag=data[at+4:at+8];payload=data[at+8:at+8+size]
        crc=struct.unpack('>I',data[at+8+size:at+12+size])[0]
        assert zlib.crc32(tag+payload)&0xffffffff==crc
        at+=size+12
        if tag==b'IEND':ended=True;break
    assert ended and at==len(data)
class PracticeNotationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.revisions=read(CONTENT/'sheet-revisions-v6.json')
        cls.previous={i['metadata']['id']:i for i in read(CONTENT/'sheet-revisions-v5.json')}
        cls.manifest=read(CONTENT/'engraving/practice-layout-v2.json')
    def test_new_versions_preserve_music_and_every_previous_version(self):
        self.assertEqual(len(self.revisions),len(self.previous))
        self.assertEqual(read(RESOURCES/'sheet-revisions-v6.json'),[i['metadata'] for i in self.revisions])
        for item in self.revisions:
            q=item['metadata'];old=self.previous[q['id']];restored=copy.deepcopy(item)
            self.assertEqual(q['version'],old['metadata']['version']+1)
            restored['metadata']['version']-=1;restored['metadata']['sheet_layout']=old['metadata']['sheet_layout'];restored['metadata'].pop('reference_display')
            for kind in ('main','scale'):
                self.assertIn(f'/versions/{q["version"]}/',q['score_assets'][kind]['url'])
                restored['metadata']['score_assets'][kind]['url']=old['metadata']['score_assets'][kind]['url']
            self.assertEqual(restored,old)
    def test_every_image_and_template_matches_server_demo_and_pinned_hash(self):
        self.assertEqual(self.manifest,read(RESOURCES/'practice-layout-v2.json'))
        checked=set()
        for item in self.revisions:
            q=item['metadata'];layout=q['sheet_layout'];asset=q['reference_display']
            self.assertEqual(asset,self.manifest['scores'][q['score_assets']['main']['sha256']])
            if layout['id'] not in checked:
                checked.add(layout['id']);data=(CONTENT/'sheets'/(layout['id']+'.png')).read_bytes()
                self.assertEqual(sha(data),layout['template_sha256']);self.assertEqual(struct.unpack('>II',data[16:24]),(2660,1692))
                self.assertEqual(data,(RESOURCES/(layout['id']+'.pngdata')).read_bytes())
                self.assertEqual(layout,read(CONTENT/'sheets'/(layout['id']+'.layout.json')))
            data=(CONTENT/'engraving'/(asset['resource']+'.png')).read_bytes()
            validate_png(data)
            self.assertEqual(sha(data),asset['sha256']);self.assertEqual(len(data),asset['size_bytes']);self.assertLess(len(data),2097152)
            self.assertEqual(struct.unpack('>II',data[16:24]),(asset['pixel_width'],asset['pixel_height']))
            self.assertEqual(data,(RESOURCES/(asset['resource']+'.pngdata')).read_bytes())
    def test_equal_candidates_align_and_all_natural_exceptions_have_real_bar_geometry(self):
        self.assertEqual(self.manifest['style_sha256'],sha((ROOT/'scripts/engraving/practice-review-v1.mss').read_bytes()))
        modes=set()
        for item in self.revisions:
            q=item['metadata'];layout=q['sheet_layout'];a,b=layout['systems'];asset=q['reference_display'];modes.add(asset['layout_mode'])
            if asset['layout_mode']=='equal':
                audit=self.manifest['audit'][q['score_assets']['main']['sha256']]
                self.assertGreaterEqual(audit['minimum_notehead_centres_sp'],1.6)
                self.assertLess(audit['max_barline_error'],2)
            self.assertEqual(a['barline_x'],b['barline_x'])
            widths=[y-x for x,y in zip(a['barline_x'][1:],a['barline_x'][2:])]
            self.assertLess(max(widths)-min(widths),.002)
            self.assertEqual([s['staff_line_y'] for s in asset['geometry']['systems']],[a['staff_line_y'],b['staff_line_y']])
            for s in asset['geometry']['systems']:
                self.assertEqual(len(s['barline_x']),5)
                self.assertTrue(all(x<y for x,y in zip(s['barline_x'],s['barline_x'][1:])))
                if asset['layout_mode']=='equal':self.assertLess(max(abs(x-y) for x,y in zip(s['barline_x'],a['barline_x'])),2)
        self.assertEqual(modes,{'equal','natural'})
    def test_backend_selects_new_preview_only_for_new_snapshot(self):
        import sys,types
        fake=types.ModuleType('django.conf');fake.settings=types.SimpleNamespace(CONTENT_ROOT=CONTENT)
        old=sys.modules.get('django.conf');sys.modules['django.conf']=fake
        try:
            spec=importlib.util.spec_from_file_location('preview',ROOT/'backend/solfege/engraving.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
            for item in self.revisions[:8]:
                q=item['metadata'];self.assertEqual(module.reference_asset(q),q['reference_display'])
                previous=self.previous[q['id']]['metadata'];self.assertNotEqual(module.reference_asset(previous)['sha256'],q['reference_display']['sha256'])
        finally:
            if old is None:sys.modules.pop('django.conf',None)
            else:sys.modules['django.conf']=old

if __name__=='__main__':unittest.main(verbosity=2)
