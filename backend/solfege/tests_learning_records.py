import copy
import unittest
from .self_assessment import normalize_errors
from .exam_observations import build_error_observations


class LearningRecordTests(unittest.TestCase):
    def test_self_review_preserves_multiple_categories_and_sorts_without_mutation(self):
        value = [{"measure": 5, "types": ["other", "rhythm", "pitch"]}, {"measure": 2, "types": ["pitch"]}]
        original = copy.deepcopy(value)
        self.assertEqual(normalize_errors(value, 8), [{"measure": 2, "types": ["pitch"]}, {"measure": 5, "types": ["pitch", "rhythm", "other"]}])
        self.assertEqual(value, original)
        self.assertEqual(normalize_errors([], 8), [])

    def test_invalid_self_review_is_not_silently_coerced(self):
        for value in (None, {}, [{"measure": True, "types": ["pitch"]}], [{"measure": 9, "types": ["pitch"]}],
                      [{"measure": 1, "types": []}], [{"measure": 1, "types": ["pitch", "pitch"]}],
                      [{"measure": 1, "types": ["unknown"]}], [{"measure": 1, "types": [{}]}],
                      [{"measure": 1, "types": ["pitch"]}] * 2, [{"measure": 1, "types": ["pitch"], "score": 0}]):
            with self.subTest(value=value), self.assertRaises(ValueError):
                normalize_errors(value, 8)

    def result(self):
        return {"status": "completed", "recognized_musicxml": '<score-partwise><part id="P1"><measure number="1"><attributes><divisions>480</divisions><key><fifths>0</fifths></key></attributes><note><pitch><step>C</step><octave>4</octave></pitch><duration>480</duration></note></measure><measure number="2"><note><pitch><step>D</step><octave>4</octave></pitch><duration>480</duration></note></measure></part></score-partwise>',
                "annotations": [{"id": "ai-1", "type": "pitch_error", "measure": 2, "note_index": 1}]}

    def test_exam_keeps_measure_xml_context_and_analysis_identity(self):
        result = self.result()
        original = copy.deepcopy(result)
        rows = build_error_observations(result, "analysis-id")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["feature_analysis_id"], "analysis-id")
        self.assertEqual(rows[0]["evidence_scope"], "measure")
        self.assertEqual(rows[0]["xml_status"], "captured")
        self.assertIn("<step>D</step>", rows[0]["measure_musicxml"])
        self.assertIn("<divisions>480</divisions>", rows[0]["context_musicxml"])
        self.assertEqual(result, original)

    def test_exam_suggestions_and_uncertain_recognition_are_not_errors(self):
        result = self.result()
        result["annotations"].extend([{"type": "notation_suggestion", "measure": 2}, {"type": "recognition_uncertain", "measure": 2}])
        rows = build_error_observations(result)
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]["recognition_uncertain"])
        result["status"] = "needs_review"
        self.assertEqual(build_error_observations(result), [])

    def test_exam_missing_or_invalid_xml_is_explicit(self):
        result = self.result()
        for xml in ("", "<score-partwise/>", '<!DOCTYPE x [<!ENTITY x "no">]><score-partwise/>'):
            result["recognized_musicxml"] = xml
            row = build_error_observations(result)[0]
            self.assertEqual(row["xml_status"], "unavailable")
            self.assertIsNone(row["measure_musicxml"])
        result["annotations"][0]["measure"] = None
        self.assertEqual(build_error_observations(result)[0]["unavailable_reason"], "missing_measure_location")
