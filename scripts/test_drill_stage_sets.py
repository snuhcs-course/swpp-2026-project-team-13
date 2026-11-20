"""Fixed stage provenance, exam isolation and slim demo coverage; no paid AI."""
import hashlib
import json
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
C=ROOT/'backend/content';R=ROOT/'frontend/IPadApp/IPadApp/Resources'
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def sha(data):return hashlib.sha256(data).hexdigest()

class StageSetsTests(unittest.TestCase):
    def test_counts_sources_and_exact_two_note_echo(self):
        course=read(C/'drills/drill-stage-sets-v1.json');pools=read(C/'question-pools.json')['records']
        memory=read(C/'drills/memory-run-v2.json');sources={s['id']:s for s in memory['sources']}
        excerpts={e['id']:e for e in memory['excerpts']}
        rhythms={r['id']:r for r in read(C/'rhythm-puzzle-v3.json')['rounds']}
        self.assertEqual([(s['number'],s['game'],len(s['questions'])) for s in course['stages']],
            [(1,'echoDragon',6),(2,'memoryRun',4),(3,'rhythmPuzzle',5),(4,'echoDragon',6),(5,'rhythmPuzzle',5),(6,'memoryRun',4)])
        for s in course['stages']:
            self.assertEqual(len({q['id'] for q in s['questions']}),len(s['questions']))
            for q in s['questions']:
                if q['collection']!='classical':self.assertEqual(pools[q['question_id']]['pool'],'practice')
                if s['game']=='memoryRun':
                    e=excerpts[q['catalog_id']];source=sources[e['sourceId']]
                    self.assertEqual(e['bars'],2);self.assertEqual(e['first'],q['first_measure'])
                    self.assertEqual(source['sha256'],q['source_sha256'])
                    self.assertEqual(sha((C/'drills'/source['file']).read_bytes()),q['source_sha256'])
                elif s['game']=='rhythmPuzzle':
                    r=rhythms[q['catalog_id']];self.assertEqual(r['source_xml_sha256'],q['source_sha256'])
                    self.assertEqual(r['question_id'],q['question_id']);self.assertEqual(r['first_measure'],q['first_measure'])
                    self.assertEqual(r['tempo_bpm'],q['bpm'])
                else:
                    raw=(C/'drills'/q['source_file']).read_bytes();self.assertEqual(sha(raw),q['source_sha256'])
                    m=ET.fromstring(raw).findall('part/measure')[q['first_measure']-1];pitches=[]
                    for i in q['note_indices']:
                        p=m.findall('note')[i-1].find('pitch')
                        pitches.append((int(p.findtext('octave'))+1)*12+{'C':0,'D':2,'E':4,'F':5,'G':7,'A':9,'B':11}[p.findtext('step')]+int(p.findtext('alter','0')))
                    self.assertEqual(q['notes'],pitches);self.assertEqual(len(pitches),2)
    def test_hash_publication_and_complete_small_demo(self):
        name='drill-stage-sets-v1.json';course=read(C/'drills'/name)
        manifest=read(C/'client-content-manifest.json')
        self.assertEqual(manifest['assets'][name]['sha256'],sha((C/'drills'/name).read_bytes()))
        self.assertEqual((C/'drills'/name).read_bytes(),(R/name).read_bytes())
        index=read(R/'small-demo-index.json');self.assertEqual(read(R/index['files']['drill-stage-sets-v1']),course)
        memory={e['id'] for e in read(R/index['files']['memory-run-v2'])['excerpts']}
        rhythm={r['id'] for r in read(R/index['files']['rhythm-puzzle-v3'])['rounds']}
        for s in course['stages']:
            if s['game']=='echoDragon':continue
            self.assertTrue({q['catalog_id'] for q in s['questions']} <= (memory if s['game']=='memoryRun' else rhythm))
        self.assertLess(sum((R/n).stat().st_size for n in index['required_files']),6*1024*1024)

if __name__=='__main__':unittest.main()
