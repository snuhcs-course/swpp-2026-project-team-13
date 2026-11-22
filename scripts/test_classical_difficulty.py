"""Real playback tempo, shared formula, hash pinning and non-classical isolation."""
import copy
import json
import unittest
import build_classical_difficulty as b
from solfege.practice_bank import timed_practice_question,visible_ids

class ClassicalDifficultyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.value=b.build()
        cls.questions={r['metadata']['id']:r for r in b.current_sources(b.CONTENT,include_classical=True) if r['metadata'].get('collection')=='classical'}
    def test_all_classical_scores_match_the_shared_formula_at_actual_playback_tempo(self):
        self.assertEqual(len(self.questions),34)
        for key,row in self.questions.items():
            entry=self.value['records'][key];q=row['metadata']
            result=timed_practice_question(q)
            self.assertAlmostEqual(result['difficulty_score'],entry['score'])
            self.assertEqual(b.quarter_bpm(result['tempo']),entry['quarter_bpm'])
            self.assertEqual(entry['reference_quarter_bpm'],b.quarter_bpm(b.resolve_tempo(q['time_signature'])))
            self.assertNotIn('practice_level',result)
    def test_faster_classical_is_not_normalized_back_to_a_factor_of_one(self):
        nonneutral=[e for e in self.value['records'].values() if e['quarter_bpm']!=e['reference_quarter_bpm']]
        self.assertGreater(len(nonneutral),10)
        for entry in nonneutral:
            expected=max((entry['content_score']+entry['key_correction'])*entry['quarter_bpm']/entry['reference_quarter_bpm'],entry['score_floor'])
            self.assertAlmostEqual(entry['score'],expected)
    def test_overlay_is_reproducible_and_wrong_score_hash_is_not_annotated(self):
        data=(json.dumps(self.value,ensure_ascii=False,indent=2)+'\n').encode('utf-8')
        self.assertEqual(data,(b.CONTENT/'classical-difficulty-v1.json').read_bytes())
        self.assertEqual(data,(b.RES/'classical-difficulty-v1.json').read_bytes())
        manifest=json.loads((b.CONTENT/'client-content-manifest.json').read_text(encoding='utf-8'))
        import hashlib
        self.assertEqual(manifest['assets']['classical-difficulty-v1.json']['sha256'],hashlib.sha256(data).hexdigest())
        row=next(iter(self.questions.values()));q=copy.deepcopy(row['metadata'])
        q['score_assets']['main']['sha256']='0'*64
        self.assertNotIn('difficulty_score',timed_practice_question(q))
    def test_classical_questions_remain_outside_the_nine_level_practice_exam_bank(self):
        self.assertTrue(set(self.questions).isdisjoint(visible_ids()))

if __name__=='__main__':unittest.main()
