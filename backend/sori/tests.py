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


    def test_exam_plan_countins_waits_and_timer_match_all_catalog_meters(self):
        from datetime import datetime
        for version in QuestionVersion.objects.order_by("question__order"):
            original = dict(version.metadata)
            q = self.client.get(f"/api/v1/questions/{version.question_id}/").data
            a = self.post("attempts/", {"question_id":q["id"], "question_version":q["version"]}).data
            plan = a["playback_plan"]
            self.assertEqual(plan["version"], 4)
            self.assertEqual(plan["initial_delay_ms"], 2000)
            self.assertEqual(plan["pause_after_scale_ms"], 2000)
            self.assertEqual(plan["count_in"]["before_step_orders"], [1,11])
            self.assertEqual(plan["count_in"]["beats_per_measure"], q["time_signature"]["numerator"])
            self.assertEqual(plan["count_in"]["beat_unit"], q["time_signature"]["denominator"])
            self.assertEqual([s["pause_after_ms"] for s in plan["steps"]], [20000]*10+[120000])
            started = self.post(f'attempts/{a["id"]}/start/').data
            expected = {(4,4):456,(3,4):426,(6,8):423,(2,4):393,(7,8):443,(9,8):468,(12,8):516}[(q["time_signature"]["numerator"],q["time_signature"]["denominator"])]
            self.assertEqual(q["recommended_duration_seconds"], expected)
            self.assertEqual(a["question"]["recommended_duration_seconds"], expected)
            self.assertEqual((datetime.fromisoformat(started["recommended_end_at"].replace("Z","+00:00")) -
                              datetime.fromisoformat(started["started_at"].replace("Z","+00:00"))).total_seconds(), expected)
            replay = self.client.get(f'/api/v1/attempts/{a["id"]}/').data
            self.assertEqual(replay["playback_plan"], plan)
            version.refresh_from_db()
            self.assertEqual(version.metadata, original)

    def test_publish_v2_preserves_the_old_version_and_attempt_plan(self):
        old_item=json.loads((settings.CONTENT_ROOT / "catalog-v1.json").read_text(encoding="utf-8"))[0]
        current=QuestionVersion.objects.get(question_id=old_item["metadata"]["id"],version=2)
        old=QuestionVersion.objects.create(question=current.question,version=1,metadata=old_item["metadata"],main_path=old_item["main_path"],scale_path=old_item["scale_path"])
        current.question.current_version=1;current.question.save(update_fields=["current_version"])
        # The backend container does not include repository docs; keep an equivalent legacy snapshot here.
        from .playback import make_playback_plan
        legacy=make_playback_plan(old.metadata)
        legacy.update(version=3,tempo_bpm=96,instrument_profile_id="sori-piano-v1")
        legacy.pop("tempo")
        snapshot=dict(old.metadata); snapshot["recommended_duration_seconds"]=407
        attempt=Attempt.objects.create(user=self.user,question_version=old,question_snapshot=snapshot,playback_plan=legacy)
        call_command("seed_questions",verbosity=0)
        current.question.refresh_from_db();old.refresh_from_db()
        self.assertEqual(current.question.current_version,2)
        self.assertEqual(old.metadata,old_item["metadata"])
        response=self.client.get(f"/api/v1/attempts/{attempt.id}/")
        self.assertEqual(response.data["playback_plan"],legacy)
        self.assertEqual(response.data["question"]["version"],1)

    def test_full_catalog_pagination_and_owner_visibility(self):
        response = self.client.get("/api/v1/questions/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["count"], 62)
        self.assertEqual([(q["time_signature"]["numerator"], q["time_signature"]["denominator"]) for q in response.data["results"][:3]], [(6,8),(4,4),(3,4)])
        results=list(response.data["results"])
        while response.data["next"]:
            response=self.client.get(response.data["next"])
            self.assertEqual(response.status_code,200)
            results.extend(response.data["results"])
        self.assertEqual(len(results),62)
        self.assertEqual(len({q["id"] for q in results}),62)
        self.assertTrue(all(q["title"].startswith("고난도 청음") for q in results[3:]))
        # Every new problem resolves its authenticated score and final answer image.
        for summary in results[3:]:
            q=self.client.get(f'/api/v1/questions/{summary["id"]}/').data
            for asset in [q["score_assets"]["main"],q["score_assets"]["scale"],q["correct_score"]]:
                binary=self.client.get(asset["url"])
                self.assertEqual(binary.status_code,200)
                self.assertEqual(hashlib.sha256(b"".join(binary.streaming_content)).hexdigest(),asset["sha256"])
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

    def test_reference_display_is_authenticated_and_pinned_to_source(self):
        q = QuestionVersion.objects.order_by("question__order").first().metadata
        preview = self.client.get(f'/api/v1/questions/{q["id"]}/').data["correct_score"]
        response = self.client.get(preview["url"], HTTP_ACCEPT="image/png")
        self.assertEqual(response.status_code,200)
        data = b"".join(response.streaming_content)
        self.assertEqual(hashlib.sha256(data).hexdigest(),preview["sha256"])
        self.assertEqual(len(data),preview["size_bytes"])
        self.client.credentials()
        self.assertEqual(self.client.get(preview["url"],HTTP_ACCEPT="image/png").status_code,401)

    def test_submission_freezes_notation_rubric_in_job_and_keeps_note_locations(self):
        attempt, _, _ = self.submitted()
        job = claim_job()
        self.assertEqual(job.prompt_version,"sori-feedback-2-notation-1")
        self.assertIn("N4 빔과 박 묶음",job.prompt_text)
        self.assertIn("notation_suggestion",job.prompt_text)
        value = {"status":"completed","recognized_musicxml":"<score-partwise/>","score":100,"pitch_accuracy":100,"rhythm_accuracy":100,"feedback":{"summary":"음정과 리듬은 맞고 표기를 더 읽기 좋게 해 봐요.","recommendations":[]},"annotations":[{"type":"notation_error","measure":1,"note_index":2,"end_note_index":5,"message":"6/8의 빔을 3개씩 묶어 봐요."},{"type":"notation_suggestion","measure":3,"note_index":1,"end_note_index":None,"message":"권장 제자리표를 적어 봐요."}]}
        provider = {"response":{"choices":[{"finish_reason":"stop","message":{"content":json.dumps(value)}}]}}
        with self.settings(OPENROUTER_API_KEY="test-not-a-real-key"), patch("sori.grading.subprocess.run",return_value=subprocess.CompletedProcess([],0,stdout=json.dumps(provider),stderr="")):
            execute_job(job)
        job.refresh_from_db()
        self.assertEqual(job.status,"completed")
        self.assertEqual(job.score,100)
        self.assertEqual(job.annotations[0]["end_note_index"],5)
        self.assertEqual(job.annotations[1]["type"],"notation_suggestion")

    def test_repeated_create_upload_submit_never_duplicate(self):
        q = QuestionVersion.objects.first().metadata
        key = str(uuid.uuid4()); body={"question_id":q["id"], "question_version":q["version"]}
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
    def test_invalid_note_ranges_cannot_be_persisted(self):
        layout = json.loads((settings.CONTENT_ROOT / "catalog.json").read_text(encoding="utf-8"))[0]["metadata"]["sheet_layout"]
        for note,end,measure in [(0,None,1),(True,None,1),(3,2,1),(None,2,1),(1,None,None),(129,None,1)]:
            value = {"status":"completed","recognized_musicxml":"","score":100,"pitch_accuracy":100,"rhythm_accuracy":100,"feedback":{"summary":"확인해요.","recommendations":[]},"annotations":[{"type":"notation_error","measure":measure,"note_index":note,"end_note_index":end,"message":"확인해요."}]}
            with self.subTest(note=note,end=end,measure=measure), self.assertRaises(ValueError):
                validate_result(value,layout)

    def test_uncertain_result_cannot_include_numeric_scores(self):
        value={"status":"needs_review","recognized_musicxml":"","score":80,"pitch_accuracy":None,"rhythm_accuracy":None,"feedback":{"summary":"확인이 필요해요.","recommendations":[]},"annotations":[]}
        with self.assertRaises(ValueError):
            validate_result(value,{})
