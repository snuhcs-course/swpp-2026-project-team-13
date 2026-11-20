import uuid
from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings
from rest_framework.test import APIClient
from .feedback_ratings import feedback_id, state
from .models import AIFeedbackRating, Answer, Attempt, GradingJob, Question, QuestionVersion


@override_settings(AI_FEEDBACK_RATINGS_ENABLED=True)
class FeedbackRatingTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(username="feedback-learner")
        self.client = APIClient(); self.client.force_authenticate(self.user)
        question = Question.objects.create()
        version = QuestionVersion.objects.create(question=question, version=1, metadata={}, main_path="unused", scale_path="unused")
        self.attempt = Attempt.objects.create(user=self.user, question_version=version, question_snapshot={}, playback_plan={}, mode="exam", status="submitted")
        answer = Answer.objects.create(attempt=self.attempt, client_answer_id=uuid.uuid4(), revision=1,
            image="unused.png", sheet_layout_id="unused", sha256="0"*64, size_bytes=0)
        self.job = GradingJob.objects.create(attempt=self.attempt, answer=answer, status="completed", grading_version="ai-melodic-v2",
            model="test-model", reasoning_effort="medium", prompt_version="test-prompt", prompt_text="frozen", score=80,
            feedback={"summary": "구체적인 피드백", "recommendations": []})
        self.attempt.current_job = self.job; self.attempt.save()
        self.path = f"/api/v1/attempts/{self.attempt.id}/feedback-rating/"
        self.body = {"job_id": str(self.job.id), "feedback_id": feedback_id(self.job), "stars": 4, "reason": "구체적인 마디 설명이 좋았어요."}

    def test_save_edit_and_retry_keep_one_rating_and_frozen_evidence(self):
        for _ in range(2):
            response = self.client.put(self.path, self.body, format="json")
            self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(AIFeedbackRating.objects.count(), 1)
        saved = AIFeedbackRating.objects.get()
        self.assertEqual(saved.feedback_snapshot["model"], "test-model")
        self.assertEqual(saved.feedback_snapshot["prompt_version"], "test-prompt")
        self.body.update(stars=2, reason="설명이 부족했어요.")
        self.assertEqual(self.client.put(self.path, self.body, format="json").status_code, 200)
        self.assertEqual(state(self.job)["rating"]["stars"], 2)
        self.job.refresh_from_db(); self.assertEqual(self.job.score, 80)
        self.assertFalse(hasattr(self.attempt, "rating_change"))

    def test_flag_off_hides_form_rejects_writes_and_retains_data(self):
        self.client.put(self.path, self.body, format="json")
        with override_settings(AI_FEEDBACK_RATINGS_ENABLED=False):
            self.assertFalse(state(self.job)["enabled"])
            self.assertEqual(self.client.put(self.path, self.body, format="json").status_code, 409)
            self.assertEqual(AIFeedbackRating.objects.count(), 1)
        self.assertTrue(state(self.job)["enabled"])

    def test_only_owner_can_write_and_read_ratings(self):
        self.assertEqual(APIClient().put(self.path, self.body, format="json").status_code, 401)
        other = get_user_model().objects.create_user(username="other-feedback-learner")
        self.client.force_authenticate(other)
        self.assertEqual(self.client.put(self.path, self.body, format="json").status_code, 404)
        self.assertEqual(self.client.get(f"/api/v1/attempts/{self.attempt.id}/result/").status_code, 404)

    def test_invalid_and_stale_submissions_do_not_write(self):
        for change in ({"stars": 0}, {"stars": 6}, {"stars": True}, {"stars": 3.5}, {"stars": "4"},
                       {"reason": "x"*501}, {"reason": None}, {"feedback_id": "stale"}, {"job_id": str(uuid.uuid4())}):
            with self.subTest(change=change):
                response = self.client.put(self.path, {**self.body, **change}, format="json")
                self.assertIn(response.status_code, (400, 404, 409), response.data)
        for status in ("queued", "processing", "failed"):
            self.job.status = status; self.job.save()
            self.assertFalse(state(self.job)["enabled"])
            self.assertEqual(self.client.put(self.path, self.body, format="json").status_code, 409)
        self.assertEqual(AIFeedbackRating.objects.count(), 0)

    def test_result_carries_flag_and_existing_rating_and_delete_cascades(self):
        self.client.put(self.path, self.body, format="json")
        result = self.client.get(f"/api/v1/attempts/{self.attempt.id}/result/")
        self.assertEqual(result.status_code, 200, result.data)
        self.assertEqual(result.data["feedback_rating"]["rating"]["reason"], self.body["reason"])
        self.attempt.current_job = None; self.attempt.save()
        self.job.delete()
        self.assertEqual(AIFeedbackRating.objects.count(), 0)
