import io
import uuid
from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient
from . import rating
from .grading import finish_job
from .level_test import PASS_GRADE, SKIP_RATING
from .models import Answer, Attempt, ExamRatingChange, ExamRatingState, QuestionVersion
from .question_pools import ids
from .recommendation import current_versions
from .views import new_job


class PlacementTests(SimpleTestCase):
    def test_expected_grade_places_at_the_question_difficulty(self):
        for difficulty in (9., 21.5, 58.5):
            self.assertAlmostEqual(rating.performance(difficulty, 80), difficulty)

    def test_performance_grows_with_grade_and_stays_within_one_skill_unit(self):
        values = [rating.performance(21.5, g) for g in (0, 40, 64, 80, 92, 100)]
        self.assertEqual(values, sorted(values))
        skill = rating.to_skill(21.5)
        self.assertAlmostEqual(rating.to_skill(values[0]), skill - 1)
        self.assertAlmostEqual(rating.to_skill(values[-1]), skill + 1)

    def test_placement_keeps_the_best_stage(self):
        results = [(9., 92), (21.5, 85), (58.5, 30)]
        self.assertEqual(rating.placement(results), max(rating.performance(d, g) for d, g in results))
        self.assertGreater(rating.placement(results), rating.placement(results[:1]))
        with self.assertRaises(ValueError):
            rating.placement([])


class LevelTestTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        call_command("seed_questions", stdout=io.StringIO())

    def setUp(self):
        self.user = get_user_model().objects.create_user(username=f"placement-{uuid.uuid4().hex[:8]}")
        self.client = APIClient(); self.client.force_authenticate(self.user)

    def state(self):
        response = self.client.get("/api/v1/exam/level-test/")
        self.assertEqual(response.status_code, 200, response.data)
        return response.data

    def post(self, action):
        return self.client.post(f"/api/v1/exam/level-test/{action}/")

    def create(self, pending, stage=None, key=None):
        body = {"question_id": pending["question_id"], "question_version": pending["question_version"], "mode": "exam",
                "level_test_stage": pending["stage"] if stage is None else stage}
        return self.client.post("/api/v1/attempts/", body, format="json", HTTP_IDEMPOTENCY_KEY=key or str(uuid.uuid4()))

    def play(self, score):
        """Take the next stage and grade it; returns the created attempt."""
        pending = self.post("next").data
        response = self.create(pending); self.assertEqual(response.status_code, 201, response.data)
        attempt = Attempt.objects.get(id=response.data["id"])
        answer = Answer.objects.create(attempt=attempt, client_answer_id=uuid.uuid4(), revision=1, image="level-test.png",
                                       sheet_layout_id=attempt.question_snapshot["sheet_layout"]["id"], sha256="0"*64, size_bytes=0)
        job = new_job(attempt, answer); job.status = "processing"; job.save(update_fields=["status"])
        attempt.status = "submitted"; attempt.submitted_answer = answer; attempt.save()
        self.assertEqual(finish_job(job, {"status": "completed", "score": score}), 1)
        return attempt, pending

    def test_new_account_is_required_and_anonymous_requests_are_refused(self):
        state = self.state()
        self.assertEqual(state["status"], "required")
        self.assertEqual(state["next_stage"], 1)
        self.assertEqual(state["pass_grade"], PASS_GRADE)
        self.assertEqual(state["stages"], []); self.assertIsNone(state["rating"])
        self.assertFalse(state["can_finish"])
        self.assertEqual(APIClient().get("/api/v1/exam/level-test/").status_code, 401)

    def test_stage_question_is_fixed_until_used_and_comes_from_the_exam_pool(self):
        first = self.post("next"); again = self.post("next")
        self.assertEqual(first.status_code, 200, first.data); self.assertEqual(first.data, again.data)
        self.assertEqual((first.data["stage"], first.data["tier"]), (1, "easy"))
        self.assertIn(first.data["question_id"], set(ids("exam")))
        version = QuestionVersion.objects.get(question_id=first.data["question_id"], version=first.data["question_version"])
        self.assertIsNotNone(version)
        key = str(uuid.uuid4())
        created = self.create(first.data, key=key); replay = self.create(first.data, key=key)
        self.assertEqual(created.status_code, 201, created.data); self.assertEqual(created.data, replay.data)
        snapshot = created.data["exam_rating_snapshot"]
        self.assertEqual(snapshot["level_test"]["stage"], 1)
        state = self.state()
        self.assertEqual(state["status"], "in_progress")
        self.assertEqual(state["stages"][0]["attempt_id"], created.data["id"])
        self.assertIsNone(state["stages"][0]["grade"]); self.assertIsNone(state["next_stage"])
        # An ungraded stage blocks the next one, finishing and skipping.
        self.assertEqual(self.post("next").data["error"]["code"], "LEVEL_TEST_STAGE_UNAVAILABLE")
        self.assertEqual(self.post("finish").data["error"]["code"], "LEVEL_TEST_NOT_FINISHABLE")
        self.assertEqual(self.post("skip").data["error"]["code"], "LEVEL_TEST_NOT_SKIPPABLE")
        # The active stage is an ordinary unresolved exam.
        offer = self.client.get("/api/v1/exam/recommendations/").data
        self.assertEqual(offer["active_attempt_id"], created.data["id"])

    def test_only_the_offered_question_and_stage_can_be_reserved(self):
        pending = self.post("next").data
        self.assertEqual(self.create(pending, stage=2).data["error"]["code"], "LEVEL_TEST_QUESTION_MISMATCH")
        other = current_versions("exam").exclude(question_id=pending["question_id"]).first()
        wrong = dict(pending, question_id=str(other.question_id), question_version=other.version)
        self.assertEqual(self.create(wrong).data["error"]["code"], "LEVEL_TEST_QUESTION_MISMATCH")
        self.assertEqual(self.create(pending, stage=4).data["error"]["code"], "VALIDATION_ERROR")

    def test_high_scores_unlock_harder_stages_and_finish_places_once(self):
        attempts = []
        for expected_tier, score in (("easy", 92), ("medium", 85), ("hard", 61)):
            attempt, pending = self.play(score)
            self.assertEqual(pending["tier"], expected_tier)
            attempts.append((attempt, pending))
        difficulties = [p["difficulty_score"] for _, p in attempts]
        self.assertEqual(difficulties, sorted(difficulties))
        self.assertFalse(ExamRatingChange.objects.filter(attempt__user=self.user).exists())
        state = self.state()
        self.assertEqual([s["grade"] for s in state["stages"]], [92, 85, 61])
        self.assertEqual([s["passed"] for s in state["stages"]], [True, True, False])
        self.assertIsNone(state["next_stage"]); self.assertTrue(state["can_finish"])
        self.assertEqual(ExamRatingState.objects.get(user=self.user).rating, 7.0)
        finished = self.post("finish"); self.assertEqual(finished.status_code, 200, finished.data)
        expected = rating.placement([(d, g) for d, g in zip(difficulties, (92, 85, 61))])
        self.assertEqual(finished.data["status"], "completed")
        self.assertAlmostEqual(finished.data["rating"], expected)
        self.assertEqual(self.post("finish").data, finished.data)
        stored = ExamRatingState.objects.get(user=self.user)
        self.assertAlmostEqual(stored.rating, expected); self.assertEqual(stored.completed, 0)
        offer = self.client.get("/api/v1/exam/recommendations/").data
        self.assertAlmostEqual(offer["rating"]["value"], expected)
        self.assertFalse({str(a.question_version.question_id) for a, _ in attempts} & {c["question_id"] for c in offer["choices"]})

    def test_a_missed_pass_grade_ends_the_test(self):
        self.play(PASS_GRADE - 1)
        state = self.state()
        self.assertEqual(state["stages"][0]["passed"], False)
        self.assertIsNone(state["next_stage"])
        self.assertEqual(self.post("next").data["error"]["code"], "LEVEL_TEST_STAGE_UNAVAILABLE")
        finished = self.post("finish").data
        self.assertEqual(finished["status"], "completed")
        self.assertAlmostEqual(finished["rating"], rating.performance(self.state_difficulty(0), PASS_GRADE - 1))

    def state_difficulty(self, index):
        return ExamRatingState.objects.get(user=self.user).level_test["stages"][index]["difficulty_score"]

    def test_learner_may_stop_after_a_passed_stage(self):
        self.play(95)
        self.assertEqual(self.state()["next_stage"], 2)
        self.assertEqual(self.post("finish").data["status"], "completed")
        self.assertEqual(self.post("next").data["error"]["code"], "LEVEL_TEST_STAGE_UNAVAILABLE")

    def test_skip_starts_at_zero_once(self):
        skipped = self.post("skip"); self.assertEqual(skipped.status_code, 200, skipped.data)
        self.assertEqual((skipped.data["status"], skipped.data["rating"]), ("skipped", SKIP_RATING))
        self.assertEqual(self.post("skip").data, skipped.data)
        self.assertEqual(ExamRatingState.objects.get(user=self.user).rating, SKIP_RATING)
        self.assertEqual(self.post("next").data["error"]["code"], "LEVEL_TEST_STAGE_UNAVAILABLE")
        self.assertEqual(self.client.get("/api/v1/exam/recommendations/").data["rating"]["value"], SKIP_RATING)

    def test_learners_with_rated_exams_keep_the_old_flow(self):
        state, _ = ExamRatingState.objects.get_or_create(user=self.user)
        state.completed = 3; state.save()
        self.assertEqual(self.state()["status"], "not_applicable")
        self.assertEqual(self.post("skip").data["error"]["code"], "LEVEL_TEST_NOT_SKIPPABLE")
        self.assertEqual(self.post("next").data["error"]["code"], "LEVEL_TEST_STAGE_UNAVAILABLE")
