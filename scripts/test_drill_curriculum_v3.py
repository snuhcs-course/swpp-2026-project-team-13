"""The recall-load course preserves published scores, tempos and key ceilings."""
import unittest
import build_drill_curriculum_v2 as b
import build_drill_curriculum_v3 as v3

class RecallCourseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.course=v3.build()
        cls.old=b.read(b.C/'drills/drill-stage-sets-v2.json')
        cls.memory=b.read(b.C/'drills/memory-run-v3.json')
        cls.excerpts={e['id']:e for e in cls.memory['excerpts']}
    def test_reproducible_server_bundle_manifest_and_small_pack(self):
        data=b.raw(self.course)
        self.assertEqual(data,(b.C/'drills/drill-stage-sets-v3.json').read_bytes())
        self.assertEqual(data,(b.R/'drill-stage-sets-v3.json').read_bytes())
        manifest=b.read(b.C/'client-content-manifest.json')
        self.assertEqual(manifest['assets']['drill-stage-sets-v3.json']['sha256'],b.sha(data))
        index=b.read(b.R/'small-demo-index.json')
        demo=b.read(b.R/index['files']['drill-stage-sets-v3'])
        self.assertEqual(demo['stages'],[s for s in self.course['stages'] if s['rank']<=2])
    def test_all_original_questions_and_rhythm_order_and_tempos_are_preserved(self):
        for old,new in zip(self.old['stages'],self.course['stages']):
            if old['game']=='rhythmPuzzle':
                self.assertEqual([q['catalog_id'] for q in old['questions']],[q['catalog_id'] for q in new['questions']])
        old={q['catalog_id']:q for s in self.old['stages'] for q in s['questions']}
        new={q['catalog_id']:q for s in self.course['stages'] for q in s['questions']}
        self.assertEqual(old.keys(),new.keys())
        for key,q in new.items():
            for field in ['bpm','source_sha256','first_measure']:self.assertEqual(q[field],old[key][field])
    def test_recall_caps_place_dense_phrases_late_and_keep_key_progression(self):
        dense=[]
        for stage in self.course['stages']:
            if stage['game']!='memoryRun':continue
            rank=stage['rank']
            for q in stage['questions']:
                attacks=self.excerpts[q['catalog_id']]['attacks']
                self.assertLessEqual(attacks,v3.NOTE_CAPS[rank-1])
                self.assertLessEqual(abs(q['key_fifths']),b.CAPS[rank-1])
                if attacks>=17:dense.append(rank)
        self.assertGreaterEqual(len(dense),2)
        self.assertTrue(all(rank>=9 for rank in dense),dense)
    def test_more_notes_raise_recall_load_even_for_identical_notation_score(self):
        self.assertGreater(v3.recall_score({'difficulty_score':0.5},{'attacks':20}),v3.recall_score({'difficulty_score':0.5},{'attacks':8}))

if __name__=='__main__':unittest.main()
