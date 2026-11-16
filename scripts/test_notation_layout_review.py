"""Ensure the authoring comparison preserves music glyphs and fixed blank geometry."""
import collections
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('engraving_geometry',ROOT/'scripts/engraving_geometry.py')
geometry=importlib.util.module_from_spec(spec);spec.loader.exec_module(geometry)

class NotationLayoutTests(unittest.TestCase):
    def test_real_registered_glyphs_survive_uniform_system_mapping(self):
        for number in (1,2,3):
            path=ROOT/f'backend/content/engraving/excerpt-{number}-reference-v1.svg'
            original=ET.parse(path).getroot();result,metrics=geometry.canonical_reference(path)
            before=collections.Counter((n.get('class'),n.get('d'),n.get('points'),n.get('transform')) for n in geometry.music_nodes(original))
            after=collections.Counter((n.get('class'),n.get('d'),n.get('points'),n.get('transform')) for group in result if group.tag.rsplit('}',1)[-1]=='g' for n in group)
            self.assertEqual(before,after)
            self.assertEqual(metrics['systems'],2)
            self.assertEqual([len(row) for row in metrics['barlines']],[5,5])
            self.assertEqual(metrics['staff_space'],12)
            for group in result:
                if group.get('data-system'):
                    a,b,c,d,_,_=geometry.numbers(group.get('transform'))
                    self.assertEqual(a,d);self.assertEqual((b,c),(0,0))
            # Serialized artifacts must be valid standalone SVGs, without duplicate xmlns.
            ET.fromstring(ET.tostring(result))

    def blank_source(self,directory):
        original=ET.parse(ROOT/'backend/content/engraving/excerpt-2-reference-v1.svg').getroot()
        allowed={'StaffLines','BarLine','Clef','TimeSig','KeySig'}
        for node in list(original):
            if node.get('class') not in allowed:original.remove(node)
        path=Path(directory)/'blank.svg';ET.ElementTree(original).write(path,encoding='utf-8',xml_declaration=True)
        return path,original

    def test_blank_is_answer_independent_and_uses_unchanged_musescore_glyphs(self):
        with tempfile.TemporaryDirectory() as folder:
            source,original=self.blank_source(folder)
            result,layout=geometry.canonical_blank(source,4,4,0)
            first,second=layout['systems']
            self.assertEqual(first['barline_x'],second['barline_x'])
            self.assertEqual(first['staff_line_y'],[164,176,188,200,212])
            self.assertEqual(second['staff_line_y'],[340,352,364,376,388])
            bars=first['barline_x'];widths=[b-a for a,b in zip(bars[1:],bars[2:])]
            self.assertLess(max(widths)-min(widths),.002)
            self.assertEqual((bars[0],bars[-1]),(54,1276))
            glyphs=[n for g in result if g.tag.rsplit('}',1)[-1]=='g' for n in g]
            self.assertTrue(glyphs)
            self.assertTrue(all(n.get('class') in ('Clef','KeySig','TimeSig') for n in glyphs))
            original_paths={n.get('d') for n in original if n.get('class') in ('Clef','KeySig','TimeSig')}
            self.assertTrue(all(n.get('d') in original_paths for n in glyphs))
            self.assertEqual(sum(n.get('class')=='Clef' for n in glyphs),2)
            self.assertEqual(sum(n.get('class')=='TimeSig' for n in glyphs),2)
            vertical=[n for n in result if n.get('class')=='BarLine']
            self.assertEqual(len(vertical),8)
            self.assertFalse(any(n.get('d','').startswith('M54 ') for n in vertical))
            ET.fromstring(ET.tostring(result))

    def test_hidden_header_does_not_leave_a_courtesy_signature_at_the_system_end(self):
        original=ET.parse(ROOT/'backend/content/engraving/excerpt-2-reference-v1.svg').getroot()
        staves=geometry.systems(original);first=staves[0]
        signature=copy.deepcopy(next(n for n in original if n.get('class')=='TimeSig'))
        shift=first['right']-first['space']-geometry.node_box(signature)[0]
        a,b,c,d,e,f=geometry.numbers(signature.get('transform','matrix(1,0,0,1,0,0)'))
        signature.set('transform',f'matrix({a},{b},{c},{d},{e+shift},{f})');original.append(signature)
        for node in original:
            if node.get('class')!='BarLine':continue
            x,y,x2,y2=geometry.numbers(node.get('points',''))
            if abs(y-first['top'])<first['space'] and abs(x-first['bars'][-1])<first['space']*.5:
                node.set('points',f'{x-40} {y} {x2-40} {y2}')
        before=collections.Counter(n.get('d') for n in original if n.get('class')=='Note')
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'courtesy.svg';ET.ElementTree(original).write(path,encoding='utf-8',xml_declaration=True)
            result,metrics=geometry.review_reference(path)
        after=[n for g in result for n in g if n.get('class')=='Note']
        self.assertEqual(before,collections.Counter(n.get('d') for n in after))
        self.assertEqual(sum(n.get('class')=='TimeSig' for g in result for n in g),2)
        group=next(g for g in result if g.get('data-system')=='1')
        scale,_,_,_,tx,_=geometry.numbers(group.get('transform'))
        right=max(geometry.numbers(n.get('points'))[0]*scale+tx for n in group if n.get('class')=='BarLine')
        self.assertAlmostEqual(right,metrics['barlines'][0][-1],places=4)

    def test_visible_music_is_rejected_as_a_blank_template(self):
        path=ROOT/'backend/content/engraving/excerpt-2-reference-v1.svg'
        with self.assertRaisesRegex(ValueError,'visible rests'):
            geometry.canonical_blank(path,4,4,0)

    def test_relative_path_commands_and_transforms_are_bounded(self):
        node=ET.fromstring('<path d="M1 2h3v4l-1 -1z" transform="matrix(2,0,0,2,10,20)"/>')
        self.assertEqual(geometry.node_box(node),(12,24,18,32))

if __name__=='__main__':unittest.main(verbosity=2)
