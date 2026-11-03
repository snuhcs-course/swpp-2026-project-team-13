"""Check Mahler against the user source and both composers' original tempi."""
import copy
from fractions import Fraction
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET
import zipfile

from import_mahler_questions import marked_tempo, SOURCE_BLOCKS
from import_practice_questions import musical_identity
from build_classical_questions import validate_source

ROOT=Path(__file__).resolve().parents[1]
CONTENT=ROOT/'backend/content'
RESOURCES=ROOT/'frontend/IPadApp/IPadApp/Resources'
spec=importlib.util.spec_from_file_location('playback',ROOT/'backend/solfege/playback.py')
playback=importlib.util.module_from_spec(spec);spec.loader.exec_module(playback)


def catalog(name):return json.loads((CONTENT/name).read_text(encoding='utf-8'))


class ClassicalUpdateTests(unittest.TestCase):
    def test_all_thirteen_mahler_melodies_preserve_source_notes_and_complete_bars(self):
        source=CONTENT/'source/mahler';provenance=json.loads((source/'provenance.json').read_text(encoding='utf-8'))
        original=ET.parse(source/'mahler.musicxml').getroot();bars=original.findall('part/measure')
        self.assertEqual(hashlib.sha256((source/'mahler.mscz').read_bytes()).hexdigest(),provenance['source_sha256'])
        self.assertEqual(hashlib.sha256((source/'mahler.musicxml').read_bytes()).hexdigest(),provenance['xml_sha256'])
        items=catalog('mahler-catalog.json');self.assertEqual(len(items),13)
        self.assertEqual([i['block'] for i in provenance['accepted']],SOURCE_BLOCKS)
        self.assertEqual([e['measures'] for e in provenance['excluded']],[[81,88],[113,120],[121,128],[129,136],[137,138]])
        existing={i['metadata']['id'] for name in ['catalog.json','classical-catalog.json','brahms-catalog.json','additional-practice-catalog.json'] for i in catalog(name)}
        self.assertFalse(existing & {i['metadata']['id'] for i in items})
        for info,item in zip(provenance['accepted'],items):
            with zipfile.ZipFile(CONTENT/item['main_path']) as z:score=ET.fromstring(z.read('score.xml'))
            validate_source(score)
            selected=ET.Element('score-partwise');part=ET.SubElement(selected,'part')
            for b in bars[info['measures'][0]-1:info['measures'][1]]:part.append(copy.deepcopy(b))
            attrs=part.find('measure/attributes')
            if attrs is None:attrs=ET.SubElement(part.find('measure'),'attributes')
            if attrs.find('divisions') is None:ET.SubElement(attrs,'divisions').text=original.findtext('part/measure/attributes/divisions')
            self.assertEqual(musical_identity(score),musical_identity(selected))
            self.assertEqual(len(score.findall('part/measure')),8)
            if info['number'] in (7,8,11):self.assertEqual(info['mode_source'],'user_confirmed')

    def test_every_original_metronome_marking_controls_scale_countin_and_duration(self):
        for composer,filename in [('mahler','mahler-catalog.json'),('brahms','classical-tempo-revisions.json')]:
            source=CONTENT/'source'/composer
            provenance=json.loads((source/'provenance.json').read_text(encoding='utf-8'))
            bars=ET.parse(source/(composer+'.musicxml')).getroot().findall('part/measure')
            for info,item in zip(provenance['accepted'],catalog(filename)):
                q=item['metadata'];before=copy.deepcopy(q);tempo=marked_tempo(bars[info['measures'][0]-1:info['measures'][1]])
                self.assertEqual(q['tempo'],tempo)
                plan=playback.make_playback_plan(q)
                factor={'quarter':1,'half':2,'dotted_quarter':1.5,'dotted_half':3}[tempo['beat_unit']]
                self.assertEqual(plan['tempo_bpm'],tempo['bpm']*factor)
                self.assertEqual(plan['tempo'],tempo)
                # Independent wall-clock calculation for 40 melody bars, one
                # count-in before each full rendition, scale, and 324s silence.
                m=q['time_signature'];quarters=m['numerator']*4/m['denominator']
                expected=324+(40+2+q['score_assets']['scale']['measure_count'])*quarters*60/(tempo['bpm']*factor)
                self.assertAlmostEqual(playback.duration_seconds(plan,m),expected)
                self.assertEqual(plan['scale']['to_measure'],q['score_assets']['scale']['measure_count'])
                self.assertEqual(q,before)
                with self.assertRaises(ValueError):playback.make_playback_plan(q,tempo['bpm']+1)
        for t in [dict(policy_id='sori-score-tempo-1',beat_unit='quarter',bpm=0,minimum_bpm=0,maximum_bpm=0),
                  dict(policy_id='sori-score-tempo-1',beat_unit='dotted_half',bpm=100,minimum_bpm=100,maximum_bpm=100)]:
            q=copy.deepcopy(catalog('mahler-catalog.json')[0]['metadata']);q['tempo']=t
            with self.assertRaises(ValueError):playback.make_playback_plan(q)

    def test_brahms_new_versions_change_only_tempo_version_and_urls(self):
        old=catalog('brahms-catalog.json');new=catalog('classical-tempo-revisions.json')
        self.assertEqual(len(old),len(new))
        for previous,revision in zip(old,new):
            self.assertEqual(revision['metadata']['version'],2)
            restored=copy.deepcopy(revision);restored['metadata']['version']=1;restored['metadata'].pop('tempo')
            for kind in ['main','scale']:restored['metadata']['score_assets'][kind]['url']=previous['metadata']['score_assets'][kind]['url']
            self.assertEqual(restored,previous)
        # Older versions retain the former meter policy when restored.
        self.assertEqual(playback.make_playback_plan(old[0]['metadata'])['tempo_bpm'],80)
        self.assertEqual(playback.make_playback_plan(new[0]['metadata'])['tempo_bpm'],100)

    def test_bundled_assets_sheets_keys_scales_and_musescore_answers(self):
        manifest=catalog('engraving/manifest.json')
        for name in ['mahler-catalog.json','classical-tempo-revisions.json']:
            items=catalog(name)
            self.assertEqual(json.loads((RESOURCES/name).read_text(encoding='utf-8')),[i['metadata'] for i in items])
            for item in items:
                q=item['metadata'];key=q['key_signature'];layout=q['sheet_layout']
                for kind,asset in q['score_assets'].items():
                    data=(CONTENT/item[kind+'_path']).read_bytes()
                    self.assertEqual(hashlib.sha256(data).hexdigest(),asset['sha256']);self.assertEqual(len(data),asset['size_bytes'])
                    self.assertEqual(data,(RESOURCES/f'classical-{q["id"]}-{kind}.mxl').read_bytes())
                with zipfile.ZipFile(CONTENT/item['scale_path']) as z:scale=ET.fromstring(z.read('score.xml'))
                self.assertEqual((int(scale.findtext('part/measure/attributes/key/fifths')),scale.findtext('part/measure/attributes/key/mode')),(key['fifths'],key['mode']))
                notes=[n for n in scale.findall('part/measure/note') if not any(t.get('type')=='stop' for t in n.findall('tie'))]
                self.assertEqual(len(notes),15);self.assertEqual(notes[0].findtext('pitch/step'),key['tonic'][0])
                pitches=[(int(n.findtext('pitch/octave'))+1)*12+dict(C=0,D=2,E=4,F=5,G=7,A=9,B=11)[n.findtext('pitch/step')]+int(n.findtext('pitch/alter','0')) for n in notes]
                self.assertEqual([b-a for a,b in zip(pitches[:8],pitches[1:8])],[2,1,2,2,1,2,2] if key['mode']=='minor' else [2,2,1,2,2,2,1])
                self.assertEqual(hashlib.sha256((CONTENT/'sheets'/(layout['id']+'.png')).read_bytes()).hexdigest(),layout['template_sha256'])
                image=manifest['scores'][q['score_assets']['main']['sha256']]
                self.assertEqual(image['renderer'],'MuseScore Studio 4.6.3')
                data=(CONTENT/'engraving'/(image['resource']+'.png')).read_bytes()
                self.assertEqual(data,(RESOURCES/(image['resource']+'.pngdata')).read_bytes());self.assertEqual(hashlib.sha256(data).hexdigest(),image['sha256'])
                self.assertEqual(len([e for e in ET.parse(CONTENT/'engraving'/(image['resource']+'.svg')).getroot() if e.get('class')=='StaffLines']),10)

    def test_natural_order_is_shared_complete_and_reorders_existing_questions(self):
        order=catalog('classical-question-order.json')
        self.assertEqual(len(order),34);self.assertEqual(len(set(order)),34)
        self.assertEqual(order,json.loads((RESOURCES/'classical-question-order.json').read_text(encoding='utf-8')))
        all_items=[i for name in ['classical-catalog.json','brahms-catalog.json','mahler-catalog.json'] for i in catalog(name)]
        self.assertEqual(set(order),{i['metadata']['id'] for i in all_items})
        for composer,filename,expected in [('brahms','brahms-catalog.json',[10,7,9,11,3,5,6,4,1,2]),('mahler','mahler-catalog.json',[6,5,1,2,3,7,8,9,10,11,12,13,4])]:
            infos=json.loads((CONTENT/'source'/composer/'provenance.json').read_text(encoding='utf-8'))['accepted']
            lookup={i['question_id']:i.get('number',i['block']) for i in infos}
            self.assertEqual([lookup[qid] for qid in order if qid in lookup],expected)
        # The already-shipped Op.39 No.9 waltz precedes No.18, not "18 before 9".
        self.assertLess(order.index('0b353d96-a50d-5cb6-8a83-655526a4f616'),order.index('0f8cc9b3-c20a-58ac-98ee-08fb9bd24a88'))


if __name__=='__main__':unittest.main()
