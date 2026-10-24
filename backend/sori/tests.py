import hashlib
import io
import json
import subprocess
import uuid
import tempfile
from pathlib import Path
from django.conf import settings
from django.test import override_settings
from unittest.mock import patch
from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import TestCase, SimpleTestCase
from PIL import Image
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient
from .grading import claim_job, execute_job, validate_result
from .models import Answer, Attempt, GradingJob, QuestionVersion

class FlowTests(TestCase):
    @classmethod
    def setUpClass(cls):
        cls.media_directory = tempfile.TemporaryDirectory(prefix="sori-tests-", dir=settings.FILE_UPLOAD_TEMP_DIR)
        cls.media_override = override_settings(MEDIA_ROOT=cls.media_directory.name)
        cls.media_override.enable()
        super().setUpClass()

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        cls.media_override.disable()
        assert Path(cls.media_directory.name).resolve().is_relative_to(Path(settings.FILE_UPLOAD_TEMP_DIR).resolve())
        cls.media_directory.cleanup()

    @classmethod
    def setUpTestData(cls):
        call_command("seed_questions", verbosity=0)
        cls.user = get_user_model().objects.create_user(username="learner")
        cls.token = Token.objects.create(user=cls.user).key
        buffer = io.BytesIO(); Image.new("RGB", (2660,1692), "white").save(buffer, "PNG")
        cls.png = buffer.getvalue()

    def setUp(self):
        self.client = APIClient()
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + self.token)

    def post(self, path, data=None, key=None, **kwargs):
        options = {"HTTP_IDEMPOTENCY_KEY": key or str(uuid.uuid4())}
        return self.client.post("/api/v1/"+path, data, format="json", **options, **kwargs)

    def begin(self):
        q = QuestionVersion.objects.order_by("question__order").first().metadata
        response = self.post("attempts/", {"question_id":q["id"], "question_version":q["version"]})
        self.assertEqual(response.status_code, 201, response.data)
        attempt = response.data
        response = self.post(f'attempts/{attempt["id"]}/start/')
        self.assertEqual(response.status_code, 200)
        return attempt

    def upload(self, attempt, client_id=None, key=None, png=None):
        file = io.BytesIO(self.png if png is None else png); file.name="answer.png"
        return self.client.post(f'/api/v1/attempts/{attempt["id"]}/answers/', {"image":file, "client_answer_id":client_id or str(uuid.uuid4()), "answer_format_version":"1", "sheet_layout_id":attempt["question"]["sheet_layout"]["id"]}, format="multipart", HTTP_IDEMPOTENCY_KEY=key or str(uuid.uuid4()))

    def submitted(self):
        attempt = self.begin()
        answer = self.upload(attempt)
        self.assertEqual(answer.status_code, 201, answer.data)
        response = self.post(f'attempts/{attempt["id"]}/submit/', {"answer_id":answer.data["id"]})
        self.assertEqual(response.status_code, 202, response.data)
        return attempt, answer.data, response.data


    def test_exam_plan_countins_waits_and_timer_match_all_three_meters(self):
        from datetime import datetime
        for version in QuestionVersion.objects.order_by("question__order"):
            original = dict(version.metadata)
            q = self.client.get(f"/api/v1/questions/{version.question_id}/").data
            a = self.post("attempts/", {"question_id":q["id"], "question_version":q["version"]}).data
            plan = a["playback_plan"]
            self.assertEqual(plan["version"], 3)
            self.assertEqual(plan["initial_delay_ms"], 2000)
            self.assertEqual(plan["pause_after_scale_ms"], 2000)
            self.assertEqual(plan["count_in"]["before_step_orders"], [1,11])
            self.assertEqual(plan["count_in"]["beats_per_measure"], q["time_signature"]["numerator"])
            self.assertEqual(plan["count_in"]["beat_unit"], q["time_signature"]["denominator"])
            self.assertEqual([s["pause_after_ms"] for s in plan["steps"]], [20000]*10+[120000])
            started = self.post(f'attempts/{a["id"]}/start/').data
            expected = 434 if q["time_signature"]["numerator"] == 4 else 407
            self.assertEqual(q["recommended_duration_seconds"], expected)
            self.assertEqual(a["question"]["recommended_duration_seconds"], expected)
            self.assertEqual((datetime.fromisoformat(started["recommended_end_at"].replace("Z","+00:00")) -
                              datetime.fromisoformat(started["started_at"].replace("Z","+00:00"))).total_seconds(), expected)
            replay = self.client.get(f'/api/v1/attempts/{a["id"]}/').data
            self.assertEqual(replay["playback_plan"], plan)
            version.refresh_from_db()
            self.assertEqual(version.metadata, original)

    def test_three_questions_assets_and_owner_visibility(self):
        response = self.client.get("/api/v1/questions/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["count"], 3)
        self.assertEqual([(q["time_signature"]["numerator"], q["time_signature"]["denominator"]) for q in response.data["results"]], [(6,8),(4,4),(3,4)])
        attempt, answer, _ = self.submitted()
        image = self.client.get(answer["image_url"])
        self.assertEqual(hashlib.sha256(b"".join(image.streaming_content)).hexdigest(), answer["sha256"])
        stranger = get_user_model().objects.create_user(username="stranger")
        self.client.credentials(HTTP_AUTHORIZATION="Bearer "+Token.objects.create(user=stranger).key)
        self.assertEqual(self.client.get(f'/api/v1/attempts/{attempt["id"]}/').status_code, 404)
        self.assertEqual(self.client.get(answer["image_url"]).status_code, 404)

    def test_binary_accept_headers_match_the_real_ipad_client(self):
        q = QuestionVersion.objects.order_by("question__order").first().metadata
        detail = self.client.get(f'/api/v1/questions/{q["id"]}/', HTTP_ACCEPT="application/json").data
        for kind, asset in detail["score_assets"].items():
            response = self.client.get(asset["url"], HTTP_ACCEPT="application/vnd.recordare.musicxml")
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response["Content-Type"], "application/vnd.recordare.musicxml")
            self.assertEqual(hashlib.sha256(b"".join(response.streaming_content)).hexdigest(), asset["sha256"])
        response = self.client.get(detail["sheet_layout"]["template_png_url"], HTTP_ACCEPT="image/png")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response["Content-Type"], "image/png")
        b"".join(response.streaming_content)
        attempt, answer, _ = self.submitted()
        response = self.client.get(answer["image_url"], HTTP_ACCEPT="image/png")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response["Content-Type"], "image/png")
        b"".join(response.streaming_content)
        self.client.credentials()
        response = self.client.get(answer["image_url"], HTTP_ACCEPT="image/png")
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response["Content-Type"], "application/json")

    def test_repeated_create_upload_submit_never_duplicate(self):
        q = QuestionVersion.objects.first().metadata
        key = str(uuid.uuid4()); body={"question_id":q["id"], "question_version":1}
        first=self.post("attempts/",body,key); second=self.post("attempts/",body,key)
        self.assertEqual(first.data,second.data)
        self.assertEqual(Attempt.objects.count(),1)
        attempt=first.data; self.post(f'attempts/{attempt["id"]}/start/')
        client_id=str(uuid.uuid4()); key=str(uuid.uuid4())
        one=self.upload(attempt,client_id,key); two=self.upload(attempt,client_id,key)
        self.assertEqual(one.data,two.data); self.assertEqual(Answer.objects.count(),1)
        key=str(uuid.uuid4()); path=f'attempts/{attempt["id"]}/submit/'; data={"answer_id":one.data["id"]}
        first=self.post(path,data,key); second=self.post(path,data,key)
        self.assertEqual(first.data,second.data); self.assertEqual(GradingJob.objects.count(),1)
        self.assertEqual(self.upload(attempt,client_id,key=str(uuid.uuid4())).status_code,201)
        self.assertEqual(self.upload(attempt).status_code,409)

    def test_zero_score_and_feedback_survive_worker_and_reload(self):
        attempt, answer, queued = self.submitted()
        job = claim_job()
        value={"status":"completed","recognized_musicxml":"<score-partwise/>","score":0,"pitch_accuracy":0.0,"rhythm_accuracy":0.0,"feedback":{"summary":"다음에는 첫 음부터 차근차근 들어봐요.","recommendations":["리듬을 먼저 불러보세요."]},"annotations":[{"type":"rhythm_error","measure":1,"message":"첫 마디의 리듬을 비교해 보세요."}]}
        provider={"response":{"id":"fixture-provider-id","choices":[{"finish_reason":"stop","message":{"content":json.dumps(value)}}],"usage":{"cost":0.01}}}
        completed=subprocess.CompletedProcess([],0,stdout=json.dumps(provider),stderr="")
        with self.settings(OPENROUTER_API_KEY="test-not-a-real-key"), patch("sori.grading.subprocess.run",return_value=completed) as run:
            execute_job(job)
            sent=json.loads(run.call_args.kwargs["input"])
            self.assertEqual(sent["payload"]["model"],job.model)
            self.assertIn("data:image/png;base64,",sent["payload"]["messages"][1]["content"][1]["image_url"]["url"])
        response=self.client.get(f'/api/v1/attempts/{attempt["id"]}/result/')
        self.assertEqual(response.data["status"],"completed"); self.assertEqual(response.data["score"],0)
        self.assertEqual(response.data["answer_id"],answer["id"])
        self.assertGreater(response.data["annotations"][0]["bbox"]["width"],0)
        self.assertEqual(response.data["feedback"]["summary"],value["feedback"]["summary"])

    def test_failed_job_retry_pins_same_image_and_old_result_cannot_win(self):
        attempt, answer, _ = self.submitted(); job=claim_job()
        with self.settings(OPENROUTER_API_KEY="test-not-a-real-key"), patch("sori.grading.subprocess.run",side_effect=subprocess.TimeoutExpired("test",1)):
            execute_job(job)
        failed=self.client.get(f'/api/v1/attempts/{attempt["id"]}/result/').data
        self.assertEqual(failed["status"],"failed"); self.assertIsNone(failed["score"])
        retried=self.post(f'attempts/{attempt["id"]}/grading-retries/')
        self.assertEqual(retried.status_code,202)
        self.assertEqual(retried.data["answer_id"],answer["id"])
        self.assertNotEqual(retried.data["job_id"],str(job.id))
        # Even a stale worker result is fenced by job state and the current_job pointer.
        with self.settings(OPENROUTER_API_KEY=""):
            self.assertEqual(execute_job(job),0)
        self.assertEqual(self.client.get(f'/api/v1/attempts/{attempt["id"]}/result/').data["job_id"],retried.data["job_id"])

    def test_rejects_wrong_size_and_missing_auth(self):
        attempt=self.begin(); data=io.BytesIO(); Image.new("RGB",(20,20),"white").save(data,"PNG")
        self.assertEqual(self.upload(attempt,png=data.getvalue()).status_code,422)
        self.client.credentials()
        self.assertEqual(self.client.get("/api/v1/me/").status_code,401)

class ResultValidationTests(SimpleTestCase):
    def test_uncertain_result_cannot_include_numeric_scores(self):
        value={"status":"needs_review","recognized_musicxml":"","score":80,"pitch_accuracy":None,"rhythm_accuracy":None,"feedback":{"summary":"확인이 필요해요.","recommendations":[]},"annotations":[]}
        with self.assertRaises(ValueError):
            validate_result(value,{})
