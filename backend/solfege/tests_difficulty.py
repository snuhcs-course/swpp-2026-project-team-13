"""Musical and calibration invariants; no Django or model API required."""
import copy
import json
import math
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

from .difficulty import analyze, CUTOFFS, level_for_score
from .features.musicxml import read_xml

CONTENT=Path(__file__).resolve().parents[1]/'content'

def melody(notes=None,fifths=0):
    notes=notes or [('C',0),('D',0),('E',0),('F',0),('G',0),('A',0),('B',0),('C',0)]
    root=ET.Element('score-partwise',version='4.0');part=ET.SubElement(root,'part',id='P1')
    for i in range(1,9):
        bar=ET.SubElement(part,'measure',number=str(i))
        if i==1:
            a=ET.SubElement(bar,'attributes');ET.SubElement(a,'divisions').text='480'
            key=ET.SubElement(a,'key');ET.SubElement(key,'fifths').text=str(fifths);ET.SubElement(key,'mode').text='major'
            t=ET.SubElement(a,'time');ET.SubElement(t,'beats').text='4';ET.SubElement(t,'beat-type').text='4'
        for step,alter in notes:
            n=ET.SubElement(bar,'note');p=ET.SubElement(n,'pitch');ET.SubElement(p,'step').text=step
            ET.SubElement(p,'alter').text=str(alter);ET.SubElement(p,'octave').text='4'
            ET.SubElement(n,'duration').text='240';ET.SubElement(n,'type').text='eighth'
    return ET.tostring(root)

class DifficultyTests(unittest.TestCase):
    def result(self,raw,**kwargs):return analyze(raw,quarter_bpm=80,reference_quarter_bpm=80,**kwargs)

    def test_cutoffs_use_unrounded_values_and_are_pool_independent(self):
        self.assertEqual(len(CUTOFFS),8)
        for i,edge in enumerate(CUTOFFS,1):
            self.assertEqual(level_for_score(math.nextafter(edge,-math.inf)),i)
            self.assertEqual(level_for_score(edge),i+1)
        self.assertEqual(level_for_score(1_000),9)

    def test_identifiers_source_titles_and_generated_levels_do_not_enter_score(self):
        raw=melody();root=ET.fromstring(raw)
        work=ET.SubElement(root,'work');ET.SubElement(work,'work-title').text='Level 10 advanced source 9999'
        self.assertEqual(self.result(raw)['score'],self.result(ET.tostring(root))['score'])

    def test_transposition_retains_content_and_applies_signature_burden_once(self):
        a=self.result(melody())
        # The final C/D returns use the same octave; choose a uniform octave
        # transpose explicitly to avoid changing a boundary leap.
        root=ET.fromstring(melody())
        mapping={'C':('D',0,4),'D':('E',0,4),'E':('F',1,4),'F':('G',0,4),'G':('A',0,4),'A':('B',0,4),'B':('C',1,5)}
        root.find('.//fifths').text='2'
        for n in root.findall('.//note'):
            p=n.find('pitch');step,alter,octave=mapping[p.findtext('step')]
            p.find('step').text=step;p.find('alter').text=str(alter);p.find('octave').text=str(octave)
        b=self.result(ET.tostring(root))
        self.assertAlmostEqual(a['content_score'],b['content_score'],places=10)
        self.assertAlmostEqual(b['score']-a['score'],2*2/6,places=10)

    def test_previous_measure_interval_is_not_a_local_feature(self):
        raw=melody();root=ET.fromstring(raw)
        for n in root.findall('part/measure')[0].findall('note'):n.find('pitch/octave').text='6'
        self.assertAlmostEqual(self.result(raw,first=2,last=2)['score'],self.result(ET.tostring(root),first=2,last=2)['score'])
        self.assertIsNone(self.result(raw,first=2,last=2)['level'])

    def test_speed_is_applied_to_score_before_fixed_cutoffs_and_is_unbounded(self):
        item=json.loads((CONTENT/'catalog.json').read_text(encoding='utf8'))[3]
        raw=read_xml(CONTENT/item['main_path']);base=self.result(raw)
        faster=analyze(raw,quarter_bpm=120,reference_quarter_bpm=80)
        self.assertAlmostEqual(faster['score'],base['score']*1.5)
        self.assertGreater(faster['score'],100)

    def test_equivalent_quarter_and_dotted_quarter_rates_are_identical(self):
        raw=melody()
        self.assertEqual(analyze(raw,quarter_bpm=55*1.5,reference_quarter_bpm=82.5)['score'],self.result(raw)['score'])

    def test_reviewed_intermediate_and_advanced_calibration_anchors(self):
        rows=json.loads((CONTENT/'catalog.json').read_text(encoding='utf8'))
        for i,row in enumerate(rows):
            result=self.result(read_xml(CONTENT/row['main_path']))
            self.assertEqual(result['level'],5 if i<3 else 9,row['metadata']['title'])

    def test_signature_alone_does_not_turn_a_simple_melody_into_top_level(self):
        a=self.result(melody())
        # The maximum correction is eight points, regardless of dataset size.
        self.assertLessEqual(level_for_score(a['content_score']+8),4)

    def test_invalid_tempo_and_scores_are_rejected(self):
        for v in (0.,-1.,float('inf'),float('nan')):
            with self.assertRaises(ValueError):analyze(melody(),quarter_bpm=v,reference_quarter_bpm=80)
        for v in (-1.,float('inf'),float('nan')):
            with self.assertRaises(ValueError):level_for_score(v)

if __name__=='__main__':unittest.main()
