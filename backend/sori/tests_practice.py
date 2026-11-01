import copy
import io
import json
import subprocess
import tempfile
import uuid
from pathlib import Path
from unittest.mock import patch
from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.db.models import F
from django.test import TestCase, override_settings
from PIL import Image
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient
from .models import Attempt, FeatureAnalysis, GradingJob, QuestionVersion, SelfAssessmentRevision
from .grading import claim_job, execute_job


class PracticeFlowTests(TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="practice-tests-", dir=settings.FILE_UPLOAD_TEMP_DIR)
        cls.media_override = override_settings(MEDIA_ROOT=cls.directory.name)
        cls.media_override.enable()
        super().setUpClass()

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        cls.media_override.disable()
        assert Path(cls.directory.name).resolve().is_relative_to(Path(settings.FILE_UPLOAD_TEMP_DIR).resolve())
        cls.directory.cleanup()

    @classmethod
    def setUpTestData(cls):
        call_command("seed_questions", stdout=io.StringIO())
        cls.user = get_user_model().objects.create_user(username="self-review-learner")
        cls.token = Token.objects.create(user=cls.user)
        cls.q = QuestionVersion.objects.filter(version=F("question__current_version")).order_by("question__order").first()
        buffer = io.BytesIO()
        Image.new("RGB", (2660, 1692), "white").save(buffer, "PNG")
        cls.png = buffer.getvalue()

    def setUp(self):
        self.client = APIClient()
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + self.token.key)

    def create(self, mode="practice"):
        body = {"question_id": str(self.q.question_id), "question_version": self.q.version}
        if mode is not None:
            body["mode"] = mode
        response = self.client.post("/api/v1/attempts/", body, format="json", HTTP_IDEMPOTENCY_KEY=str(uuid.uuid4()))
        self.assertEqual(response.status_code, 201, response.data)
        return response.data

    def submit(self, mode="practice"):
        attempt = self.create(mode)
        path = f"/api/v1/attempts/{attempt['id']}/"
        self.assertEqual(self.client.post(path + "start/").status_code, 200)
        image = io.BytesIO(self.png)
        image.name = "answer.png"
        answer = self.client.post(path + "answers/", {"image": image, "client_answer_id": str(uuid.uuid4()),
            "answer_format_version": "1", "sheet_layout_id": attempt["question"]["sheet_layout"]["id"]}, format="multipart", HTTP_IDEMPOTENCY_KEY=str(uuid.uuid4()))
        self.assertEqual(answer.status_code, 201, answer.data)
        submitted = self.client.post(path + "submit/", {"answer_id": answer.data["id"]}, format="json", HTTP_IDEMPOTENCY_KEY=str(uuid.uuid4()))
        return attempt, path, answer.data, submitted

    def review(self, path, errors=None, completed=True, revision=0, key=None):
        return self.client.put(path + "self-assessment/", {"expected_revision": revision, "errors": errors or [], "completed": completed}, format="json", HTTP_IDEMPOTENCY_KEY=key or str(uuid.uuid4()))

    def test_practice_submits_immediately_without_any_ai_job(self):
        with patch("sori.views.new_job") as job:
            attempt, path, answer, response = self.submit()
        job.assert_not_called()
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual((response.data["status"], response.data["revision"], response.data["grading_mode"]), ("pending", 0, "self"))
        self.assertEqual(response.data["answer_id"], answer["id"])
        self.assertEqual(GradingJob.objects.count(), 0)
        saved = Attempt.objects.get(id=attempt["id"])
        self.assertIsNotNone(saved.feature_analysis_id)
        self.assertIsNone(saved.current_job_id)
        self.assertEqual(self.client.get(path + "result/").data["status"], "pending")
        retry = self.client.post(path + "grading-retries/", HTTP_IDEMPOTENCY_KEY=str(uuid.uuid4()))
        self.assertEqual(retry.status_code, 409)
        self.assertEqual(retry.data["error"]["code"], "AI_GRADING_NOT_AVAILABLE")

    def test_empty_completed_review_is_distinct_from_unreviewed(self):
        _, path, _, initial = self.submit()
        self.assertIsNone(initial.data["completed_at"])
        saved = self.review(path)
        self.assertEqual(saved.status_code, 200, saved.data)
        self.assertEqual(saved.data["status"], "completed")
        self.assertEqual(saved.data["errors"], [])
        self.assertIsNotNone(saved.data["completed_at"])
        self.assertNotIn("score", saved.data)
        self.assertEqual(SelfAssessmentRevision.objects.count(), 2)

    def test_multi_category_draft_completion_and_correction_preserve_history(self):
        attempt, path, _, _ = self.submit()
        errors = [{"measure": 3, "types": ["rhythm", "pitch"]}, {"measure": 1, "types": ["other"]}]
        draft = self.review(path, errors=errors, completed=False)
        self.assertEqual(draft.status_code, 200)
        self.assertEqual(draft.data["errors"], [{"measure": 1, "types": ["other"]}, {"measure": 3, "types": ["pitch", "rhythm"]}])
        self.assertEqual(draft.data["status"], "pending")
        complete = self.review(path, errors=draft.data["errors"], revision=1)
        self.assertEqual(complete.data["status"], "completed")
        corrected = self.review(path, errors=[], revision=2)
        self.assertEqual(corrected.data["revision"], 3)
        self.assertEqual(corrected.data["errors"], [])
        rows = SelfAssessmentRevision.objects.filter(attempt_id=attempt["id"]).order_by("revision")
        self.assertEqual(rows.count(), 4)
        self.assertEqual(rows[1].errors, draft.data["errors"])
        self.assertEqual(rows[2].errors, draft.data["errors"])

    def test_review_retry_is_idempotent_and_stale_revision_cannot_overwrite(self):
        _, path, _, _ = self.submit()
        key = str(uuid.uuid4())
        first = self.review(path, errors=[{"measure": 2, "types": ["pitch"]}], key=key)
        repeated = self.review(path, errors=[{"measure": 2, "types": ["pitch"]}], key=key)
        self.assertEqual(first.status_code, 200)
        self.assertEqual(repeated.data["revision"], first.data["revision"])
        self.assertEqual(repeated["Idempotency-Replayed"], "true")
        stale = self.review(path, errors=[], revision=0)
        self.assertEqual(stale.status_code, 409)
        self.assertEqual(stale.data["error"]["code"], "SELF_ASSESSMENT_REVISION_CONFLICT")
        self.assertEqual(self.client.get(path + "result/").data["errors"], first.data["errors"])

    def test_bad_review_and_other_users_cannot_change_the_record(self):
        _, path, _, _ = self.submit()
        for body in ({"expected_revision": True, "errors": [], "completed": True},
                     {"expected_revision": 0, "errors": [], "completed": "true"},
                     {"expected_revision": 0, "errors": [{"measure": 9, "types": ["pitch"]}], "completed": True}):
            response = self.client.put(path + "self-assessment/", body, format="json", HTTP_IDEMPOTENCY_KEY=str(uuid.uuid4()))
            self.assertEqual(response.status_code, 400)
        other = get_user_model().objects.create_user(username="other-reviewer")
        token = Token.objects.create(user=other)
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + token.key)
        self.assertEqual(self.client.get(path + "result/").status_code, 404)
        self.assertEqual(self.review(path).status_code, 404)
        self.assertEqual(SelfAssessmentRevision.objects.count(), 1)

    def test_exam_and_legacy_requests_still_enqueue_ai(self):
        for mode in ("exam", None):
            attempt, path, _, response = self.submit(mode)
            self.assertEqual(attempt["mode"], "exam")
            self.assertEqual(response.status_code, 202, response.data)
            self.assertEqual(response.data["grading_mode"], "automatic")
            self.assertEqual(self.review(path).status_code, 409)
        self.assertEqual(GradingJob.objects.count(), 2)
        self.assertEqual(SelfAssessmentRevision.objects.count(), 0)

    def test_submission_retry_and_pinned_analysis_do_not_duplicate_records(self):
        attempt, path, answer, _ = self.submit()
        original = Attempt.objects.get(id=attempt["id"]).feature_analysis_id
        repeated = self.client.post(path + "submit/", {"answer_id": answer["id"]}, format="json", HTTP_IDEMPOTENCY_KEY=str(uuid.uuid4()))
        self.assertEqual(repeated.status_code, 200)
        self.assertEqual(SelfAssessmentRevision.objects.count(), 1)
        other_payload = copy.deepcopy(FeatureAnalysis.objects.get(id=original).payload)
        self.assertEqual(other_payload["question_version"], self.q.version)
        self.assertEqual(Attempt.objects.get(id=attempt["id"]).feature_analysis_id, original)

    def test_exam_worker_persists_xml_evidence_with_the_pinned_analysis(self):
        attempt, _, _, response = self.submit("exam")
        self.assertEqual(response.status_code, 202)
        job = claim_job()
        xml = '<score-partwise><part id="P1"><measure number="1"><attributes><divisions>480</divisions></attributes><note><pitch><step>D</step><octave>4</octave></pitch><duration>480</duration></note></measure></part></score-partwise>'
        value = {"status": "completed", "recognized_musicxml": xml, "score": 50, "pitch_accuracy": 50.0,
                 "rhythm_accuracy": 100.0, "feedback": {"summary": "Check the first pitch.", "recommendations": []},
                 "annotations": [{"type": "pitch_error", "measure": 1, "note_index": 1, "message": "Compare the first pitch."}]}
        provider = {"response": {"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(value)}}]}}
        completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(provider), stderr="")
        with self.settings(OPENROUTER_API_KEY="test-not-a-real-key"), patch("sori.grading.subprocess.run", return_value=completed):
            self.assertEqual(execute_job(job), 1)
        job.refresh_from_db()
        self.assertEqual(job.recognized_musicxml, xml)
        self.assertEqual(job.status, "completed")
        self.assertEqual(len(job.error_observations), 1)
        evidence = job.error_observations[0]
        self.assertEqual(evidence["source"], "ai")
        self.assertEqual(evidence["feature_analysis_id"], attempt["feature_analysis_id"])
        self.assertEqual(evidence["xml_status"], "captured")
        self.assertIn("<step>D</step>", evidence["measure_musicxml"])

    def test_changed_source_asset_cannot_silently_create_an_attempt(self):
        metadata = copy.deepcopy(self.q.metadata)
        metadata["score_assets"]["main"]["sha256"] = "0" * 64
        QuestionVersion.objects.filter(pk=self.q.pk).update(metadata=metadata)
        response = self.client.post("/api/v1/attempts/", {"question_id": str(self.q.question_id),
            "question_version": self.q.version, "mode": "practice"}, format="json", HTTP_IDEMPOTENCY_KEY=str(uuid.uuid4()))
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.data["error"]["code"], "QUESTION_ANALYSIS_UNAVAILABLE")
        self.assertEqual(Attempt.objects.count(), 0)
