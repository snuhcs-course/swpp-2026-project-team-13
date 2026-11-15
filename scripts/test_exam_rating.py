"""Offline model, frozen partition and real-bank recommendation checks."""
import collections
import json
import math
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
from solfege import rating
from solfege.assessment import schema_for_version, validate_result_for_version, RESULT_SCHEMA


class RatingTests(unittest.TestCase):
    def test_new_exams_always_require_numeric_grades_including_blank_answers(self):
        schema=schema_for_version('ai-melodic-v2')
        self.assertEqual(schema['properties']['status']['enum'],['completed'])
        self.assertEqual(schema['properties']['score']['type'],'integer')
        self.assertIn('needs_review',RESULT_SCHEMA['properties']['status']['enum'])
        value=dict(status='completed',recognized_musicxml='',score=0,pitch_accuracy=0,rhythm_accuracy=0,
                   feedback=dict(summary='미응답입니다.',recommendations=[]),annotations=[])
        self.assertEqual(validate_result_for_version(value,{},'ai-melodic-v2')['score'],0)
        value.update(status='needs_review',score=None,pitch_accuracy=None,rhythm_accuracy=None)
        with self.assertRaises(ValueError):validate_result_for_version(value,{},'ai-melodic-v2')
        rules=(ROOT/'backend/solfege/notation-rules-v2.txt').read_text(encoding='utf8')
        self.assertIn('그 부분은 오답으로 평가한다',rules)
        self.assertNotIn('확정적 감점을 하지 않는다',rules)

    def test_scale_is_continuous_roundtrips_and_has_no_100_ceiling(self):
        for x in [0,7,7.5,9.5,13,30,55,62,68,74,100,200]:
            self.assertAlmostEqual(rating.from_skill(rating.to_skill(x)),x)
        self.assertGreater(rating.update(120,20,120,100)['after'],120)
        for edge in rating.KNOTS[1:]:
            self.assertLess(abs(rating.update(edge-1e-7,20,edge,90)['after']-
                                rating.update(edge+1e-7,20,edge,90)['after']),2e-5)

    def test_equal_difficulty_means_80_and_zero_is_a_result(self):
        for score in [0,7,8.5,11,20,40,60,80,150]:
            self.assertAlmostEqual(rating.expected_fraction(score,score),.8)
            self.assertAlmostEqual(rating.update(score,20,score,80)['delta'],0)
        self.assertLess(rating.update(7,0,7,0)['delta'],0)

    def test_grade_and_difficulty_are_monotone(self):
        for r in [0,7,8.5,20,40,80,120]:
            for grade in [0,60,79,80,100]:
                changes=[rating.update(r,20,d,grade)['delta'] for d in [0,7,9,20,40,80,120]]
                self.assertEqual(changes,sorted(changes))
            changes=[rating.update(r,20,40,g)['delta'] for g in range(101)]
            self.assertEqual(changes,sorted(changes))

    def test_malformed_numbers_and_bounded_steps(self):
        for bad in [-1,True,None,'7',math.nan,math.inf]:
            with self.assertRaises(ValueError):rating.to_skill(bad)
        for bad in [-1,101,True,math.nan]:
            with self.assertRaises(ValueError):rating.update(7,0,7,bad)
        for bad in [-1,1.5,True]:
            with self.assertRaises(ValueError):rating.learning_rate(bad)
        self.assertGreaterEqual(rating.learning_rate(100000),.25)
        for r in [0,7,40,100]:
            for g in [0,100]:
                u=rating.update(r,0,r,g)
                self.assertLessEqual(abs(rating.to_skill(u['after'])-rating.to_skill(r)),.500000001)

    def test_frozen_partition_is_complete_disjoint_and_transposition_grouped(self):
        raw=(ROOT/'backend/content/question-pools.json').read_bytes()
        self.assertEqual(raw,(ROOT/'frontend/IPadApp/IPadApp/Resources/question-pools.json').read_bytes())
        pool=json.loads(raw); scores=json.loads((ROOT/'backend/content/practice-difficulty.json').read_text(encoding='utf8'))['records']
        self.assertEqual(set(pool['records']),set(scores))
        counts=collections.Counter(v['pool'] for v in pool['records'].values())
        self.assertEqual(counts,{'practice':1550,'exam':387})
        families=collections.defaultdict(set)
        for value in pool['records'].values():families[value['family']].add(value['pool'])
        self.assertTrue(all(len(pools)==1 for pools in families.values()))
        ordered=sorted(scores,key=lambda q:(scores[q]['score'],q))
        for first in range(0,len(ordered),100):
            bucket=ordered[first:first+100]
            share=sum(pool['records'][q]['pool']=='exam' for q in bucket)/len(bucket)
            self.assertTrue(.1 <= share <= .3,(first,share))

    def test_real_bank_offers_three_at_initial_rating_and_never_recycles(self):
        pools=json.loads((ROOT/'backend/content/question-pools.json').read_text(encoding='utf8'))['records']
        scores=json.loads((ROOT/'backend/content/practice-difficulty.json').read_text(encoding='utf8'))['records']
        questions=[rating.Question(q,scores[q]['score']) for q in scores if pools[q]['pool']=='exam']
        for seed in range(20):
            choices=rating.recommendations(7,questions,seed=seed)
            self.assertEqual(len({c['question_id'] for c in choices}),3)
            self.assertGreater(choices[0]['difficulty_score'],7)
            self.assertLess(choices[2]['difficulty_score'],7)
            self.assertEqual(choices,rating.recommendations(7,list(reversed(questions)),seed=seed))
        seen=[q.id for q in questions]
        self.assertTrue(all(c['question_id'] is None for c in rating.recommendations(7,questions,seen=seen)))
        self.assertIsNone(rating.recommendations(0,questions)[2]['question_id'])
        self.assertTrue(all(c['question_id'] is None for c in rating.recommendations(7,[])))


if __name__=='__main__':unittest.main()
