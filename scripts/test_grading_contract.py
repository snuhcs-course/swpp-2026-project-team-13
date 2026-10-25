"""Exercise the production model-output validator without Django, a DB or paid requests."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("assessment", ROOT / "backend/sori/assessment.py")
assessment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assessment)
LAYOUT = json.loads((ROOT / "backend/content/catalog.json").read_text(encoding="utf-8"))[0]["metadata"]["sheet_layout"]

class AssessmentTests(unittest.TestCase):
    def result(self):
        return {"status":"completed","recognized_musicxml":"<score-partwise/>","score":100,"pitch_accuracy":100,"rhythm_accuracy":100,"feedback":{"summary":"잘했어요.","recommendations":[]},"annotations":[]}
    def test_notation_advice_and_note_group_survive_without_overwriting_score_or_xml(self):
        value = self.result()
        value["annotations"] = [{"type":"notation_error","measure":1,"note_index":2,"end_note_index":5,"message":"빔을 3개씩 묶어 봐요."},{"type":"notation_suggestion","measure":3,"note_index":1,"end_note_index":None,"message":"권장 제자리표를 적어 봐요."}]
        before = copy.deepcopy(value)
        result = assessment.validate_result(value,LAYOUT)
        self.assertEqual(result["score"],100)
        self.assertEqual(result["recognized_musicxml"],before["recognized_musicxml"])
        self.assertEqual(result["annotations"][0]["end_note_index"],5)
        self.assertEqual(result["annotations"][0]["bbox"]["y"],(164-90)/846)
        self.assertEqual(result["annotations"][1]["type"],"notation_suggestion")
    def test_invalid_note_ranges_are_rejected(self):
        for note,end,measure in [(0,None,1),(True,None,1),(3,2,1),(None,2,1),(1,None,None),(129,None,1),(1.5,None,1),(2,"3",1)]:
            value = self.result()
            value["annotations"] = [{"type":"notation_error","measure":measure,"note_index":note,"end_note_index":end,"message":"확인해요."}]
            with self.subTest(note=note,end=end,measure=measure), self.assertRaises(ValueError):
                assessment.validate_result(value,LAYOUT)
    def test_legacy_annotations_and_zero_score_remain_valid(self):
        value = self.result()
        value.update(score=0,pitch_accuracy=0,rhythm_accuracy=0)
        value["annotations"] = [{"type":"missing_note","measure":1,"message":"첫 음을 적어 봐요."}]
        self.assertEqual(assessment.validate_result(value,LAYOUT)["score"],0)
    def test_uncertain_result_cannot_claim_numeric_scores(self):
        value = self.result()
        value["status"] = "needs_review"
        with self.assertRaises(ValueError):
            assessment.validate_result(value,LAYOUT)
        value.update(score=None,pitch_accuracy=None,rhythm_accuracy=None)
        self.assertEqual(assessment.validate_result(value,LAYOUT)["status"],"needs_review")

if __name__ == "__main__":
    unittest.main()
