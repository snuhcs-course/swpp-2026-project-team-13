"""Tempo, key ceilings, rhythm exclusions and immutable-server delivery."""
from collections import Counter
from copy import deepcopy
from fractions import Fraction as F
import hashlib
import unittest
import tempfile
import build_drill_curriculum_v2 as b
import build_drill_curriculum_review as review
from test_drill_curriculum_v3 import RecallCourseTests
from solfege.rhythm import grade

class CurriculumTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files,cls.audit=b.build()
        cls.course=cls.files['drill-stage-sets-v2.json']
        cls.memory=cls.files['memory-run-v3.json'];cls.rhythm=cls.files['rhythm-puzzle-v4.json']
    def test_reproduction_does_not_rewrite_old_versions(self):
        manifest=b.read(b.C/'client-content-manifest.json')
        for name,value in self.files.items():
            data=b.raw(value);server=b.C/name if name=='rhythm-puzzle-v4.json' else b.C/'drills'/name
            self.assertEqual(data,server.read_bytes());self.assertEqual(data,(b.R/name).read_bytes())
            self.assertEqual(manifest['assets'][name]['sha256'],b.sha(data))
        self.assertEqual(self.files['rhythm-engraving-v4.json']['catalog_sha256'],b.sha(b.raw(self.rhythm)))
        self.assertEqual(self.files['memory-groove-v2.json']['catalogSha256'],b.sha(b.raw(self.memory)))
    def test_all_memory_stages_respect_actual_score_key_and_are_two_bars(self):
        stages=[s for s in self.course['stages'] if s['game']=='memoryRun']
        self.assertEqual(len(stages),10)
        sources={s['id']:s for s in self.memory['sources']};fingerprints=[]
        for rank,s in enumerate(stages,1):
            self.assertEqual(len(s['questions']),4)
            for q in s['questions']:
                source=sources[q['source_id']]
                xml=b.parse_xml((b.C/q['source_file']).read_bytes())
                actual=int(xml.findtext('part/measure/attributes/key/fifths'))
                self.assertEqual(actual,q['key_fifths']);self.assertEqual(actual,source['fifths'])
                self.assertLessEqual(abs(actual),b.CAPS[rank-1]);self.assertEqual(q['bars'],2)
                fingerprints.append(q['fingerprint'])
                self.assertEqual(q['bpm'],q['performance']['quarterBpm'])
        self.assertEqual(len(set(fingerprints)),40)
        self.assertGreaterEqual(sum(q['collection']=='classical' for s in stages for q in s['questions']),30)
    def test_classical_tempo_and_actual_seconds_agree_in_both_games(self):
        tempos=self.audit['classical_tempos'];sources={s['id']:s for s in self.memory['sources']}
        for e in self.memory['excerpts']:
            s=sources[e['sourceId']]
            if s['collection']!='classical':continue
            bpm=tempos[s['id']]['quarterBpm'];self.assertEqual(s['quarterBpm'],bpm)
            self.assertEqual(e['performance']['quarterBpm'],bpm)
            self.assertAlmostEqual(e['performance']['seconds'],e['durationQuarters']*60/bpm,places=5)
        for r in self.rhythm['rounds']:
            if r['collection']!='classical':continue
            bpm=tempos[r['question_id']]['quarterBpm'];self.assertEqual(r['tempo_bpm'],bpm)
            self.assertAlmostEqual(r['difficulty']['performance']['seconds'],float(F(r['total_duration']))*60/bpm,places=5)
        for s in self.course['stages']:
            for q in s['questions']:
                if q['collection']=='classical':self.assertEqual(q['bpm'],tempos[q['question_id']]['quarterBpm'])
    def test_rhythm_removes_trivial_sustains_and_unplayably_dense_classical(self):
        excluded=self.audit['rhythm_excluded'];reasons=Counter(x['reason'] for x in excluded)
        self.assertGreater(reasons['sustained_without_rhythm_contrast'],0)
        self.assertGreater(reasons['excessive_attack_rate'],0)
        self.assertTrue(any(x['question_id']=='e9dc82c3-e60e-5809-913d-26c8c766db37' for x in excluded))
        selected={q['catalog_id'] for s in self.course['stages'] if s['game']=='rhythmPuzzle' for q in s['questions']}
        for r in self.rhythm['rounds']:
            self.assertLessEqual(r['difficulty']['performance']['notesPerSecond'],5)
            self.assertLessEqual(r['difficulty']['performance']['peakNotesPerSecond'],8)
        self.assertEqual(len(selected),50)
        tiles={t['id']:t for t in self.rhythm['tiles']}
        for r in self.rhythm['rounds']:
            self.assertTrue(grade(r,dict(placements=r['solution'],ties=r['solution_ties']),tiles)['correct'])
    def test_speed_changes_difficulty_and_course_never_uses_exam_sources(self):
        for kind in ['memory','rhythm']:
            slow=b.performance(.4,60,12,8,F(1,4),kind)
            fast=b.performance(.4,120,12,8,F(1,4),kind)
            self.assertGreater(fast['raw'],slow['raw']);self.assertAlmostEqual(fast['notesPerSecond'],slow['notesPerSecond']*2)
        pools=b.read(b.C/'question-pools.json')['records']
        for s in self.course['stages']:
            self.assertNotEqual(s['game'],'echoDragon')
            for q in s['questions']:
                if q['collection']!='classical':self.assertEqual(pools[q['question_id']]['pool'],'practice')
        for game in ['memoryRun','rhythmPuzzle']:
            means=[sum(q['difficulty_score'] for q in s['questions'])/len(s['questions']) for s in self.course['stages'] if s['game']==game]
            self.assertTrue(all(a<b for a,b in zip(means,means[1:])),(game,means))
    def test_new_small_demo_is_closed_and_full_banks_are_not_bundled(self):
        index=b.read(b.R/'small-demo-index.json');files=index['files']
        course=b.read(b.R/files['drill-stage-sets-v2'])
        memory=b.read(b.R/files['memory-run-v3']);rhythm=b.read(b.R/files['rhythm-puzzle-v4'])
        mids={e['id'] for e in memory['excerpts']};rids={r['id'] for r in rhythm['rounds']}
        for s in course['stages']:
            self.assertLessEqual(s['rank'],2)
            self.assertTrue({q['catalog_id'] for q in s['questions']} <= (mids if s['game']=='memoryRun' else rids))
        self.assertLess(sum((b.R/n).stat().st_size for n in index['required_files']),6*1024*1024)
        self.assertNotIn('memory-run-v3.json',index['required_files'])
    def test_review_xmls_preserve_two_measures_key_and_exact_tempo(self):
        with tempfile.TemporaryDirectory(dir=b.ROOT/'.tmp') as directory:
            output=b.Path(directory);jobs=review.build(output)
            self.assertEqual(len(jobs),90)
            for stage in self.course['stages']:
                for slot,q in enumerate(stage['questions'],1):
                    root=b.parse_xml((output/stage['game']/f'S{stage["number"]:02}-Q{slot:02}.xml').read_bytes())
                    bars=root.findall('part/measure');self.assertEqual(len(bars),2)
                    self.assertEqual(float(bars[0].find('direction/sound').get('tempo')),q['bpm'])
                    if stage['game']=='memoryRun':self.assertEqual(int(bars[0].findtext('attributes/key/fifths')),q['key_fifths'])
                    if q['collection']=='classical':
                        t=self.audit['classical_tempos'][q['question_id']]
                        metro=bars[0].find('direction/direction-type/metronome')
                        self.assertEqual(metro.findtext('beat-unit'),t['tempoBeatUnit'].replace('dotted_',''))
                        self.assertEqual(float(metro.findtext('per-minute')),t['tempoDisplayBpm'])
                        if t['tempoBeatUnit'].startswith('dotted_'):self.assertEqual([e.tag for e in metro],['beat-unit','beat-unit-dot','per-minute'])

if __name__=='__main__':unittest.main()
