"""Validate the unpublished review course against exact original audible notes."""
from collections import Counter
from fractions import Fraction as F
import hashlib
from pathlib import Path
import statistics
import tempfile
import unittest

import build_drill_score_drafts as draft
from solfege.features import analyze_bytes, select_span
from solfege.features.musicxml import read_xml, parse_xml


class DrillDraftTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = draft.ROOT/'.tmp'; temporary.mkdir(exist_ok=True)
        cls.directory = tempfile.TemporaryDirectory(prefix='drill-review-',dir=temporary)
        cls.output = Path(cls.directory.name)
        cls.manifest = draft.build(cls.output)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def questions(self):
        return [q for s in self.manifest['stages'] for q in s['questions']]

    def test_course_lengths_independent_questions_and_mostly_classical_memory(self):
        stages = self.manifest['stages']
        self.assertEqual(len(stages),30)
        self.assertEqual(len({q['id'] for q in self.questions()}),150)
        for s in stages:
            self.assertEqual(s['game'],draft.PATTERN[(s['number']-1)%9])
            self.assertEqual(len(s['questions']),draft.COUNTS[s['game']])
            for q in s['questions']:
                measures = parse_xml((self.output/q['xml']).read_bytes()).findall('part/measure')
                self.assertEqual(len(measures),1 if s['game']=='echoDragon' else 2)
        memory = [q for q in self.questions() if q['game']=='memoryRun']
        self.assertEqual(sum(q['collection']=='classical' for q in memory),32)
        self.assertEqual(len({q['fingerprint'] for q in memory}),40)

    def test_exact_source_pitch_timing_key_and_no_dangling_ties(self):
        cache = {}
        for q in self.questions():
            with self.subTest(question=q['id']):
                actual = analyze_bytes((self.output/q['xml']).read_bytes(),question_id='review')
                root = parse_xml((self.output/q['xml']).read_bytes())
                first = root.find('part/measure')
                self.assertLess(list(first).index(first.find('direction')),list(first).index(first.find('note')))
                data = read_xml(draft.CONTENT/q['source_file'])
                self.assertEqual(hashlib.sha256(data).hexdigest(),q['source_sha256'])
                if q['game']=='echoDragon':
                    self.assertEqual([a['midi'] for a in actual['attacks']],q['notes'])
                    source = parse_xml(data).findall('part/measure')[q['first_measure']-1]
                    notes = source.findall('note')
                    self.assertEqual([draft.midi(notes[i-1]) for i in q['note_indices']],q['notes'])
                    continue
                if q['source_file'] not in cache:
                    cache[q['source_file']] = analyze_bytes(data,question_id='source')
                original = cache[q['source_file']]
                start = q['first_measure']
                span = select_span(original,start,start+1)
                self.assertFalse(span['external_ties'])
                event_ids = {e['id'] for e in original['events'] if start<=e['measure']<start+2}
                offset = sum((F(m['actual_duration_qn']) for m in original['measures'][:start-1]),F(0))
                expected = [(a['midi'],F(a['absolute_onset_qn'])-offset,F(a['sounding_duration_qn']))
                            for a in original['attacks'] if a['id'] in event_ids]
                observed = [(a['midi'],F(a['absolute_onset_qn']),F(a['sounding_duration_qn'])) for a in actual['attacks']]
                self.assertEqual(observed,expected)
                self.assertEqual(actual['measures'][0]['key_signature'],original['measures'][start-1]['key_signature'])
                for measure in actual['measures']:
                    self.assertEqual(F(measure['actual_duration_qn']),F(measure['expected_duration_qn']))

    def test_exam_exclusion_and_progression(self):
        pools = draft.read(draft.CONTENT/'question-pools.json')['records']
        for q in self.questions():
            if q['collection']!='classical':
                self.assertEqual(pools.get(q['question_id'],{}).get('pool'),'practice',q['id'])
        for game in ['memoryRun','rhythmPuzzle']:
            means = [statistics.mean(q['difficulty'] for q in s['questions'])
                     for s in self.manifest['stages'] if s['game']==game]
            self.assertTrue(all(a<b for a,b in zip(means,means[1:])),(game,means))
        echo = [q for q in self.questions() if q['game']=='echoDragon']
        self.assertEqual({abs(q['interval']) for q in echo},set(range(13)))
        self.assertEqual(len({tuple(q['notes']) for q in echo}),60)
        for distance in range(1,13):
            self.assertTrue(any(q['interval']==distance for q in echo))
            self.assertTrue(any(q['interval']==-distance for q in echo))

    def test_stage_and_game_books_preserve_every_question(self):
        for stage in self.manifest['stages']:
            root = parse_xml((self.output/stage['xml']).read_bytes())
            self.assertEqual(len(root.findall('part/measure')),len(stage['questions'])*(1 if stage['game']=='echoDragon' else 2))
        for game,count in [('memoryRun',80),('rhythmPuzzle',100),('echoDragon',60)]:
            root = parse_xml((self.output/f'00-{game}-all.xml').read_bytes())
            self.assertEqual(len(root.findall('part/measure')),count)
            words = [n.text for n in root.findall('part/measure/direction/direction-type/words')]
            self.assertEqual(words,[q['id'] for q in self.questions() if q['game']==game])


if __name__=='__main__':
    unittest.main()
