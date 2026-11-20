import copy
import json
import subprocess
import time
import uuid
from types import SimpleNamespace
from unittest.mock import patch
from django.contrib.auth import get_user_model
from django.test import SimpleTestCase, TestCase, override_settings
from django.conf import settings
from django.utils import timezone
from .coaching import freeze_for_job, generate_coach
from .models import Answer, Attempt, GradingJob, Question, QuestionVersion
from .reference_marks import note_map, reference_marks


class CoachingHistoryTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(username="coach-learner")
        question = Question.objects.create()
        self.version = QuestionVersion.objects.create(question=question, version=1, metadata={}, main_path="unused", scale_path="unused")

    def attempt(self, user=None, mode="exam", status="completed"):
        a = Attempt.objects.create(user=user or self.user, question_version=self.version, question_snapshot={}, playback_plan={},
            mode=mode, status="submitted", submitted_at=timezone.now())
        answer = Answer.objects.create(attempt=a, client_answer_id=uuid.uuid4(), revision=1, image="unused.png", sheet_layout_id="unused", sha256="0"*64, size_bytes=0)
        job = GradingJob.objects.create(attempt=a, answer=answer, status=status, score=80 if status == "completed" else None,
            grading_version="ai-melodic-v3", model="test", prompt_version="test", prompt_text="test", reasoning_effort="medium",
            annotations=[{"type": "pitch_error", "measure": 1}])
        a.current_job = job; a.save()
        return a, answer, job

    def test_history_is_owned_completed_exam_current_jobs_only_and_retry_is_frozen(self):
        old, _, real = self.attempt()
        self.attempt(mode="practice")
        self.attempt(status="failed")
        self.attempt(user=get_user_model().objects.create_user(username="other-coach-learner"))
        # A replaced job is not a separate past exam.
        GradingJob.objects.create(attempt=old, answer=real.answer, status="completed", score=50,
            grading_version="ai-melodic-v2", model="test", prompt_version="test", prompt_text="test", reasoning_effort="medium")
        current, answer, job = self.attempt(status="queued")
        frozen = freeze_for_job(current, answer)
        self.assertEqual([r["job_id"] for r in frozen["history"]["records"]], [str(real.id)])
        job.coaching = frozen; job.save()
        self.attempt()
        self.assertEqual(freeze_for_job(current, answer), frozen)

    @override_settings(OPENROUTER_API_KEY="test-only")
    def test_failed_or_invalid_coaching_keeps_current_grade_and_stores_fallback(self):
        result = {"score": 80, "feedback": {"summary": "Original grading facts", "recommendations": []},
                  "annotations": [{"type": "pitch_error", "measure": 1}]}
        job = SimpleNamespace(coaching={"prompt_version": "b3-test", "prompt_text": "test", "history": {"available": False, "records": []}},
                              model="test", reasoning_effort="medium")
        original = copy.deepcopy(result)
        for failure in (subprocess.TimeoutExpired("test", 1), ValueError("invalid JSON")):
            with self.subTest(failure=failure), patch("subprocess.run", side_effect=failure):
                feedback, meta = generate_coach(job, result, "<score-partwise/>", "unused", time.monotonic()+20)
                self.assertEqual(meta["status"], "fallback")
                self.assertFalse(feedback["coach"]["history_used"])
                self.assertEqual(result, original)

    @override_settings(OPENROUTER_API_KEY="test-only")
    def test_successful_short_coach_and_provider_audit(self):
        result = {"score": 80, "feedback": {"summary": "Original", "recommendations": []},
                  "annotations": [{"type": "pitch_error", "measure": 1}]}
        coach = {"headline": "1마디의 첫 음을 확인해보세요.", "detail": "", "kind": "observation", "scope": "current", "history_used": False,
                 "evidence": [{"measure": 1, "reason": "음정 차이"}], "history_evidence_ids": [], "evidence_warning": []}
        response = {"response": {"id": "coach-response", "usage": {"cost": 0.01}, "choices": [{"finish_reason": "stop", "message": {"content": json.dumps(coach)}}]}}
        job = SimpleNamespace(coaching={"prompt_version": "b3-test", "prompt_text": "frozen", "history": {"available": False, "records": []}}, model="test", reasoning_effort="medium")
        with patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, json.dumps(response), "")):
            feedback, meta = generate_coach(job, result, "<score-partwise/>", "unused", time.monotonic()+20)
        self.assertEqual(feedback["coach"]["headline"], coach["headline"])
        self.assertEqual(meta["provider_request_id"], "coach-response")
        self.assertEqual(meta["status"], "completed")
        self.assertEqual(feedback["summary"], "Original")


class ReferenceMarkTests(SimpleTestCase):
    def test_verified_reference_indices_and_legacy_measure_fallback(self):
        maps = note_map()
        catalog = json.loads((settings.CONTENT_ROOT/"sheet-revisions-v6.json").read_text(encoding="utf-8"))
        q = next(item["metadata"] for item in catalog if item["metadata"]["reference_display"]["sha256"] in maps)
        annotation = {"id": "ai-1", "measure": 1, "note_index": 1, "end_note_index": None, "type": "pitch_error", "message": "첫 음 확인"}
        job = SimpleNamespace(attempt=SimpleNamespace(question_snapshot=q), status="completed", grading_version="ai-melodic-v3", annotations=[annotation])
        mark = reference_marks(job)[0]
        self.assertEqual(mark["style"], "glyph"); self.assertEqual(len(mark["glyphs"]), 1)
        # A current grade cannot invent pixel positions, and old index semantics stay coarse.
        job.grading_version = "ai-melodic-v2"
        self.assertEqual(reference_marks(job)[0]["style"], "measure")
        job.grading_version = "ai-melodic-v3"
        for change, style in (({"note_index": 128}, "measure"), ({"type": "extra_note"}, "measure"), ({"type": "rhythm_error"}, "underline")):
            job.annotations = [{**annotation, **change}]
            self.assertEqual(reference_marks(job)[0]["style"], style)
        for kind in ("recognition_uncertain", "notation_suggestion"):
            job.annotations = [{**annotation, "type": kind}]
            self.assertEqual(reference_marks(job), [])
